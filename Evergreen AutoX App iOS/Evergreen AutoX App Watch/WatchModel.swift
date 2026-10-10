import Foundation
import Observation
import WatchKit

// Follows the session the phone has open, with the phone's ME car, pins and
// nicknames, and fetches its results straight from the server (public reads,
// no device token).
@Observable
final class WatchModel {
    private(set) var context: WatchContext?
    private(set) var drivers: [Driver] = []
    private(set) var loadedSessionID: Int?
    private(set) var errorMessage: String?

    @ObservationIgnored private var link: WatchLink?
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let contextKey = "watchContext"

    init() {
        if let data = defaults.data(forKey: Self.contextKey) {
            context = try? JSONDecoder().decode(WatchContext.self, from: data)
        }
        let link = WatchLink { [weak self] context in
            guard let self else { return }
            Task { @MainActor in self.apply(context) }
        }
        self.link = link
        link.start()
    }

    func apply(_ new: WatchContext) {
        guard new != context else { return }
        if new.sessionID != context?.sessionID || new.baseURL != context?.baseURL {
            drivers = []
            loadedSessionID = nil
            errorMessage = nil
        }
        context = new
        defaults.set(try? JSONEncoder().encode(new), forKey: Self.contextKey)
    }

    var isLive: Bool { context?.isLive ?? false }

    var me: Driver? {
        guard let number = context?.meNumber else { return nil }
        return drivers.first { $0.startNumber == number }
    }

    // ME and the pinned cars, in finishing order.
    var friends: [Driver] {
        guard let context else { return [] }
        return drivers.filter { $0.startNumber == context.meNumber || context.pins.contains($0.startNumber) }
    }

    func isMe(_ driver: Driver) -> Bool {
        driver.startNumber == context?.meNumber
    }

    func displayName(_ driver: Driver) -> String {
        context?.nicknames[driver.startNumber] ?? driver.name
    }

    func gapToMe(_ driver: Driver) -> Double? {
        guard let mine = me?.best, let theirs = driver.best, !isMe(driver) else { return nil }
        return theirs - mine
    }

    // A failure leaves the last results up, as on the phone.
    func refresh() async {
        guard let context, let sessionID = context.sessionID,
              let baseURL = URL(string: context.baseURL.hasSuffix("/") ? context.baseURL : context.baseURL + "/")
        else { return }
        do {
            let loaded = try await APIClient(baseURL: baseURL, deviceToken: nil).drivers(sessionID: sessionID)
            guard self.context?.sessionID == sessionID else { return }
            let previousRuns = loadedSessionID == sessionID && self.context?.meNumber == context.meNumber
                ? me?.runs.count
                : nil
            drivers = loaded
            loadedSessionID = sessionID
            errorMessage = nil
            if let previousRuns, let runs = me?.runs.count, runs > previousRuns {
                WKInterfaceDevice.current().play(.notification)
            }
        } catch {
            guard self.context?.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
    }
}
