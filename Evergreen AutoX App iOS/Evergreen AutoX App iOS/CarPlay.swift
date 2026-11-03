import CarPlay
import Foundation

// Follows the session the phone app has open, the way the Watch app does, and
// fetches its results itself: in the car the phone is locked, so AppModel's
// live refresh is not running. The context is saved because CarPlay can
// launch the app without its window scene, and with it AppModel.
final class CarPlayFeed {
    static let shared = CarPlayFeed()

    private(set) var context: WatchContext?
    private(set) var drivers: [Driver] = []
    private(set) var loadedSessionID: Int?
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private static let contextKey = "carPlayContext"

    private init() {
        if let data = defaults.data(forKey: Self.contextKey) {
            context = try? JSONDecoder().decode(WatchContext.self, from: data)
        }
    }

    func update(_ new: WatchContext) {
        guard new != context else { return }
        if new.sessionID != context?.sessionID || new.baseURL != context?.baseURL {
            drivers = []
            loadedSessionID = nil
            errorMessage = nil
        }
        context = new
        defaults.set(try? JSONEncoder().encode(new), forKey: Self.contextKey)
        onChange?()
    }

    var me: Driver? { context?.me(in: drivers) }

    // A failure leaves the last results up, as on the phone.
    func refresh() async {
        guard let context, let sessionID = context.sessionID,
              let baseURL = URL(string: context.baseURL.hasSuffix("/") ? context.baseURL : context.baseURL + "/")
        else { return }
        do {
            let loaded = try await APIClient(baseURL: baseURL, deviceToken: nil).drivers(sessionID: sessionID)
            guard self.context?.sessionID == sessionID else { return }
            drivers = loaded
            loadedSessionID = sessionID
            errorMessage = nil
        } catch {
            guard self.context?.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
        onChange?()
    }
}

// The Watch app's two pages as CarPlay tabs: ME's last run, and ME with the
// pinned friends. Driving-task apps may only use list, information, grid and
// tab bar templates, and must stay glanceable, hence no drill-down.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let feed = CarPlayFeed.shared
    private let lastRun = CPListTemplate(title: "Last Run", sections: [])
    private let friends = CPListTemplate(title: "Friends", sections: [])
    private var pollTask: Task<Void, Never>?
    private var polledSession: (sessionID: Int?, baseURL: String?, live: Bool)?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        lastRun.tabTitle = "Last Run"
        lastRun.tabImage = UIImage(systemName: "stopwatch")
        friends.tabTitle = "Friends"
        friends.tabImage = UIImage(systemName: "person.2")
        let tabs = CPTabBarTemplate(templates: [lastRun, friends])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        feed.onChange = { [weak self] in self?.render() }
        render()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        feed.onChange = nil
        pollTask?.cancel()
        pollTask = nil
        polledSession = nil
        self.interfaceController = nil
    }

    private func render() {
        restartPollingIfNeeded()
        renderLastRun()
        renderFriends()
    }

    // An old event is fetched once.
    private func restartPollingIfNeeded() {
        let context = feed.context
        let key = (sessionID: context?.sessionID, baseURL: context?.baseURL, live: context?.isLive ?? false)
        if let polledSession, polledSession == key { return }
        polledSession = key
        pollTask?.cancel()
        guard key.sessionID != nil else { return }
        pollTask = Task { [feed] in
            while !Task.isCancelled {
                await feed.refresh()
                guard key.live else { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var loadMessage: String? {
        guard feed.drivers.isEmpty else { return nil }
        if feed.context?.sessionID == nil { return "Open AutoX Live on your iPhone and pick an event." }
        if let error = feed.errorMessage { return error }
        if feed.loadedSessionID == nil { return "Loading…" }
        return "No results in this session yet."
    }

    // Rows rather than an information template, whose small grey labels can't
    // be read at a glance; list rows carry the same colored badges as Friends.
    private func renderLastRun() {
        if let message = loadMessage {
            lastRun.emptyViewTitleVariants = [message]
            lastRun.updateSections([])
            return
        }
        guard let me = feed.me else {
            lastRun.emptyViewTitleVariants = ["Tap FIND ME on your iPhone to follow your car."]
            lastRun.updateSections([])
            return
        }
        let rows = [lastRunRow(me), positionRow(me), bestRow(me)]
        lastRun.updateSections([CPListSection(items: rows)])
    }

    private func lastRunRow(_ me: Driver) -> CPListItem {
        guard let last = me.runs.last else {
            return CPListItem(text: "No runs yet", detailText: nil, image: badge("—", fill: Self.neutralFill))
        }
        let detail = "Run \(last.number) · \(penalty(last))"
        let image: UIImage
        if last.dnf {
            image = badge("DNF", fill: Self.dnfFill)
        } else if let best = me.best, last.seconds <= best {
            image = badge("BEST", fill: Self.behindFill)
        } else if let best = me.best {
            let gap = last.seconds - best
            image = badge(LapTime.gap(gap), fill: gap <= 1 ? Self.aheadFill : Self.meFill)
        } else {
            image = badge("—", fill: Self.neutralFill)
        }
        return CPListItem(text: last.timeString, detailText: detail, image: image)
    }

    // The badge is the overall place; the row names the class place and how
    // far off the next car up in that class (or overall, with no class) is.
    private func positionRow(_ me: Driver) -> CPListItem {
        let image = badge("P\(me.position)", caption: "OVERALL", fill: Self.meFill)
        let text: String
        let ahead: Driver?
        let target: String
        let leading: Bool
        if let carClass = me.carClass, let inClass = me.positionInClass {
            text = "P\(inClass) in \(carClass)"
            ahead = feed.drivers.first { $0.carClass == carClass && $0.positionInClass == inClass - 1 }
            target = "P\(inClass - 1)"
            leading = inClass == 1
        } else {
            text = "P\(me.position) overall"
            ahead = feed.drivers.first { $0.position == me.position - 1 }
            target = "P\(me.position - 1)"
            leading = me.position == 1
        }
        var detail: String?
        if let theirs = ahead?.best, let mine = me.best {
            detail = String(format: "%.3f to %@", mine - theirs, target)
        } else if leading, me.best != nil {
            detail = "Leading"
        }
        return CPListItem(text: text, detailText: detail, image: image)
    }

    private func bestRow(_ me: Driver) -> CPListItem {
        let count = me.timedRuns.count
        let bestRun = me.timedRuns.min { $0.seconds < $1.seconds }
        return CPListItem(
            text: "Best \(me.bestString)",
            detailText: bestRun.map { "Set on run \($0.number)" },
            image: badge("\(count)", caption: count == 1 ? "RUN" : "RUNS", fill: Self.neutralFill)
        )
    }

    private func renderFriends() {
        if let message = loadMessage {
            friends.emptyViewTitleVariants = [message]
            friends.updateSections([])
            return
        }
        guard let context = feed.context else { return }
        let rows = context.friends(in: feed.drivers).map { driver in
            let isMe = context.isMe(driver)
            var detail = "P\(driver.position) · Best \(driver.bestString)"
            let badge: UIImage
            if isMe {
                if let carClass = driver.carClass, let inClass = driver.positionInClass {
                    detail = "P\(driver.position) · P\(inClass) \(carClass) · Best \(driver.bestString)"
                }
                badge = self.badge("YOU", fill: Self.meFill)
            } else if let gap = context.gapToMe(driver, in: feed.drivers) {
                badge = self.badge(LapTime.gap(gap), fill: gap < 0 ? Self.aheadFill : Self.behindFill)
            } else {
                badge = self.badge("—", fill: Self.neutralFill)
            }
            return CPListItem(text: isMe ? "You" : context.displayName(driver), detailText: detail, image: badge)
        }
        friends.emptyViewTitleVariants = ["Pin friends on your iPhone to see them here."]
        friends.updateSections(rows.isEmpty ? [] : [CPListSection(items: rows)])
    }

    private static let meFill = UIColor(red: 0xEC / 255, green: 0x30 / 255, blue: 0x13 / 255, alpha: 1)
    private static let aheadFill = UIColor(red: 0xD9 / 255, green: 0x82 / 255, blue: 0x00 / 255, alpha: 1)
    private static let behindFill = UIColor(red: 0x2E / 255, green: 0x9E / 255, blue: 0x4F / 255, alpha: 1)
    private static let neutralFill = UIColor(white: 0.36, alpha: 1)
    private static let dnfFill = UIColor(red: 0x9B / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)

    // CarPlay can run light or dark; white on a solid fill reads in both.
    private func badge(_ label: String, caption: String? = nil, fill: UIColor) -> UIImage {
        let size = CPListItem.maximumImageSize
        let format = UIGraphicsImageRendererFormat(for: interfaceController?.carTraitCollection ?? UITraitCollection())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            fill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height * 0.2).fill()
            let main = fitted(label, maxSize: size.height * (caption == nil ? 0.42 : 0.4), width: size.width * 0.88)
            guard let caption else {
                draw(label, main, centeredAt: size.height / 2, width: size.width)
                return
            }
            let small = fitted(caption.uppercased(), maxSize: size.height * 0.2, width: size.width * 0.88)
            let total = main.height + small.height
            let top = (size.height - total) / 2
            draw(label, main, centeredAt: top + main.height / 2, width: size.width)
            draw(caption.uppercased(), small, centeredAt: top + main.height + small.height / 2, width: size.width)
        }
    }

    private func fitted(_ text: String, maxSize: CGFloat, width: CGFloat) -> (attributes: [NSAttributedString.Key: Any], height: CGFloat) {
        var fontSize = maxSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var textSize = CGSize.zero
        repeat {
            attributes = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            textSize = (text as NSString).size(withAttributes: attributes)
            fontSize -= 1
        } while textSize.width > width && fontSize > 6
        return (attributes, textSize.height)
    }

    private func draw(_ text: String, _ style: (attributes: [NSAttributedString.Key: Any], height: CGFloat), centeredAt y: CGFloat, width: CGFloat) {
        let textWidth = (text as NSString).size(withAttributes: style.attributes).width
        (text as NSString).draw(at: CGPoint(x: (width - textWidth) / 2, y: y - style.height / 2), withAttributes: style.attributes)
    }

    private func penalty(_ run: Run?) -> String {
        guard let run else { return "No runs yet" }
        if run.dnf { return "Off course" }
        if run.cones > 0 { return run.cones == 1 ? "+1 cone" : "+\(run.cones) cones" }
        return "Clean run"
    }
}
