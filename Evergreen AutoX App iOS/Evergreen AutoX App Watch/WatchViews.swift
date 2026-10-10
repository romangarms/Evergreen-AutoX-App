import SwiftUI

// The phone's palette, dark only: the Watch is always on black.
private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let egInk = Color(hex: 0xF3F2F2)
    static let egRed = Color(hex: 0xEC3013)
    static let egGray = Color(hex: 0x7D7979)
    static let egRule = Color(hex: 0x333333)
    static let egRowRule = Color(hex: 0x262626)
    static let egMeBg = Color(hex: 0x1A1A1A)
    static let egPenalty = Color(hex: 0xFF9783)
    static let egAhead = Color(hex: 0xFF563C)
}

// The big numbers on the first page round to hundredths, as in the concept.
private func shortTime(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.2f", seconds) }
    let minutes = Int(seconds) / 60
    return String(format: "%d:%05.2f", minutes, seconds - Double(minutes * 60))
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private struct RefreshKey: Hashable {
        let active: Bool
        let sessionID: Int?
        let baseURL: String?
        let live: Bool
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            active: scenePhase == .active,
            sessionID: model.context?.sessionID,
            baseURL: model.context?.baseURL,
            live: model.isLive
        )
    }

    var body: some View {
        TabView {
            LastRunPage()
            FriendsPage()
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        // Polls like the phone's live pages, but only while the Watch app is
        // on screen; an old event is fetched once.
        .task(id: refreshKey) {
            let key = refreshKey
            guard key.active, key.sessionID != nil else { return }
            while !Task.isCancelled {
                await model.refresh()
                guard key.live else { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .kerning(1.2)
            .foregroundStyle(Color.egRed)
    }
}

private struct WatchMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.egGray)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
    }
}

// What a page shows before it has drivers to show.
private struct LoadState: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if model.context?.sessionID == nil {
            WatchMessage(text: "Open AutoX Live on your iPhone and pick an event.")
        } else if let error = model.errorMessage {
            WatchMessage(text: error)
        } else if model.loadedSessionID == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WatchMessage(text: "No results in this session yet.")
        }
    }
}

struct LastRunPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.drivers.isEmpty {
                    LoadState()
                } else if let me = model.me {
                    LastRunCard(driver: me)
                } else {
                    WatchMessage(text: "Tap FIND ME on your iPhone to follow your car.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PageTitle(text: "LAST RUN")
                }
            }
        }
    }
}

private struct LastRunCard: View {
    let driver: Driver

    private var last: Run? { driver.runs.last }

    private var lastString: String {
        guard let last else { return "—" }
        return last.dnf ? "DNF" : shortTime(last.seconds)
    }

    private var penalty: String {
        guard let last else { return "No runs yet" }
        if last.dnf { return "Off course" }
        if last.cones > 0 { return last.cones == 1 ? "+1 cone" : "+\(last.cones) cones" }
        return "Clean run"
    }

    private var position: String {
        if let carClass = driver.carClass, let inClass = driver.positionInClass {
            return "P\(inClass) \(carClass)"
        }
        return "P\(driver.position)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(lastString)
                .font(.system(size: 44, weight: .heavy))
                .monospacedDigit()
                .kerning(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Color.egInk)
            Text(penalty)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(last.map { $0.dnf || $0.cones > 0 } == true ? Color.egPenalty : Color.egGray)
            Color.egRule
                .frame(height: 2)
                .padding(.vertical, 9)
            HStack(alignment: .top, spacing: 8) {
                stat("BEST", driver.best.map(shortTime) ?? "—", color: .egInk, alignment: .leading)
                Spacer(minLength: 0)
                stat("POS", position, color: .egRed, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stat(_ label: String, _ value: String, color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1)
                .foregroundStyle(Color.egGray)
            Text(value)
                .font(.system(size: 19, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(color)
        }
    }
}

struct FriendsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.drivers.isEmpty {
                    LoadState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.friends) { driver in
                                FriendRow(driver: driver)
                            }
                            if model.friends.count <= 1 {
                                Text("Pin friends on your iPhone to see them here.")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.egGray)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 10)
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PageTitle(text: "FRIENDS")
                }
            }
        }
    }
}

private struct FriendRow: View {
    @Environment(WatchModel.self) private var model
    let driver: Driver

    var body: some View {
        let isMe = model.isMe(driver)
        let gap = model.gapToMe(driver)
        HStack(spacing: 6) {
            Text("P\(driver.position)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.egGray)
                .frame(width: 28, alignment: .leading)
            Text(isMe ? "You" : model.displayName(driver))
                .font(.system(size: 14, weight: .heavy))
                .lineLimit(1)
                .foregroundStyle(isMe ? Color.egRed : Color.egInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(driver.bestString)
                    .font(.system(size: 14, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Color.egInk)
                if !isMe {
                    // Red: they're ahead of you.
                    Text(gap.map(LapTime.gap) ?? "—")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(gap.map { $0 < 0 } == true ? Color.egAhead : Color.egGray)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(isMe ? Color.egMeBg : Color.clear)
        .overlay(alignment: .top) {
            Color.egRowRule.frame(height: 1)
        }
    }
}
