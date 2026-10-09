import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var nav = NavTracker()
    @State private var showOrgPrompt = false
    @State private var orgIDText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
        .background(Color.egBg)
        // The tables stop fitting a phone beyond this, and the base sizes
        // are already too small to shrink.
        .dynamicTypeSize(.large ... .xxxLarge)
        .modifier(AppleCredentialWatcher())
        .task(id: scenePhase == .active && model.wantsLiveRefresh) {
            guard scenePhase == .active, model.wantsLiveRefresh else { return }
            while !Task.isCancelled {
                // Counted from the last load of any kind, so coming back to
                // the app reloads at once and a manual reload restarts the wait.
                let wait = model.lastSessionLoad
                    .addingTimeInterval(AppModel.liveRefreshInterval)
                    .timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                } else {
                    await model.refreshSessionData()
                }
            }
        }
        .alert("Speedhive Organization", isPresented: $showOrgPrompt) {
            TextField("\(AppModel.defaultOrgID)", text: $orgIDText)
                .keyboardType(.numberPad)
            Button("Load Events") {
                model.orgIDString = orgIDText.trimmingCharacters(in: .whitespaces)
                Task { await model.loadEvents() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Events are pulled from this organization ID. Leave empty for Evergreen Speedway.")
        }
    }

    private var headerInfo: (tag: String, title: String, sub: String?, changesEvent: Bool) {
        let sessionName = model.selectedSession.map { model.sessionLabel($0) }
        switch model.screen {
        case .driver(let position):
            let driver = model.driver(at: position)
            return ("DRIVER", driver.map { "P\($0.position) — #\($0.startNumber)" } ?? "Driver", sessionName, false)
        case .compare:
            return ("VS", "Head-to-head", sessionName, false)
        case .leaderboard(let courseID):
            let course = model.leaderboardCourses.first { $0.id == courseID }
            return ("LEADERBOARD", course?.name ?? "Leaderboard", course?.createdBy.map { "Created by \($0)" }, false)
        case .leaderboardDriver(let courseID, let position):
            let course = model.leaderboardCourses.first { $0.id == courseID }
            let driver = model.leaderboardDriver(at: position)
            return ("DRIVER", driver?.name ?? "Driver", course?.name, false)
        case .acceleration:
            return ("LEADERBOARD", "Acceleration", nil, false)
        case .accelerationEntry(let id):
            let entry = model.accelerationEntries?.first { $0.id == id }
            return ("VEHICLE", entry?.title ?? "Vehicle", "Acceleration", false)
        case nil:
            switch model.tab {
            case .live:
                // Many events share a name, so the date is what says which one
                // is loaded.
                let sub = AppModel.eventDate(model.selectedEvent?.startDate) ?? sessionName
                return ("LIVE", model.selectedEvent?.name ?? "AutoX Live", sub, true)
            case .friends:
                return ("FRIENDS", "Your people", sessionName, false)
            case .events:
                return ("EVENTS", "Pick an event", nil, false)
            case .boards:
                return ("BOARDS", "Leaderboards", "Posted by people using the app", false)
            case .settings:
                return ("SETUP", "Account & app", nil, false)
            }
        }
    }

    private var header: some View {
        let info = headerInfo
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                EGTag(text: info.tag)
                Text(info.title)
                    .egFont(16, weight: .heavy)
                    .foregroundStyle(Color.egInk)
                    .lineLimit(1)
            }
            .padding(.trailing, hasHeaderMenu ? 40 : 0)
            if let sub = info.sub {
                if info.changesEvent {
                    Button {
                        model.select(tab: .events)
                    } label: {
                        HStack(spacing: 8) {
                            Text(sub)
                                .egFont(11.5, weight: .semibold)
                                .kerning(0)
                                .foregroundStyle(Color.egInk)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Text("CHANGE EVENT")
                                Image(systemName: "chevron.right")
                                    .egFont(9, weight: .heavy)
                            }
                        }
                    }
                    .buttonStyle(EGChipButtonStyle(tint: .egRed))
                    .padding(.top, 12)
                    if model.sessions.count > 1 {
                        sessionMenu
                    }
                } else {
                    Text(sub)
                        .egFont(11.5)
                        .foregroundStyle(Color.egGrayDark)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .topTrailing) {
            if case .driver(let position) = model.screen, let driver = model.driver(at: position) {
                driverMenu(driver)
            } else if model.tab == .events, model.screen == nil {
                eventsMenu
            } else if showsLiveMenu {
                liveMenu
            }
        }
        .overlay(alignment: .bottom) {
            Color.egDivider.frame(height: 2)
        }
    }

    private var sessionMenu: some View {
        Menu {
            ForEach(AppModel.byMostRecent(model.sessions)) { session in
                Button {
                    model.pickSession(session.id)
                } label: {
                    if session.id == model.selectedSessionID {
                        Label(model.sessionLabel(session), systemImage: "checkmark")
                    } else {
                        Text(model.sessionLabel(session))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                EGColumnLabel(text: "SESSION")
                Text(model.selectedSession.map { model.sessionLabel($0) } ?? "—")
                    .egFont(11.5, weight: .semibold)
                    .foregroundStyle(Color.egInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .egFont(9, weight: .heavy)
                    .foregroundStyle(Color.egGray)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
    }

    private var showsLiveMenu: Bool {
        model.tab == .live && model.screen == nil && !model.drivers.isEmpty
    }

    private var hasHeaderMenu: Bool {
        if case .driver = model.screen { return true }
        return model.screen == nil && (model.tab == .events || showsLiveMenu)
    }

    private var liveMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Sort by", selection: $model.liveSortByClass) {
                Label("Overall Position", systemImage: "list.number").tag(false)
                Label("Class Position", systemImage: "square.stack.3d.up").tag(true)
            }
        } label: {
            menuIcon
        }
        .padding(.trailing, 4)
    }

    private var backLabel: String? {
        switch model.screen {
        case .driver: model.tab == .friends ? "FRIENDS" : "RESULTS"
        case .compare: "BACK"
        case .leaderboard, .acceleration: "BOARDS"
        case .leaderboardDriver: "LEADERBOARD"
        case .accelerationEntry: "ACCELERATION"
        case nil: nil
        }
    }

    private var eventsMenu: some View {
        Menu {
            Button {
                Task { await model.loadEvents() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            if model.devMode {
                Button {
                    orgIDText = model.orgIDString
                    showOrgPrompt = true
                } label: {
                    Label("Set Organization ID…", systemImage: "building.2")
                }
            }
        } label: {
            menuIcon
        }
        .padding(.trailing, 4)
    }

    private func driverMenu(_ driver: Driver) -> some View {
        let pinned = model.pins.contains(driver.startNumber)
        let isMe = driver.startNumber == model.meNumber
        return Menu {
            Button {
                model.meNumber = isMe ? nil : driver.startNumber
            } label: {
                Label(isMe ? "This Isn't Me" : "This Is Me", systemImage: isMe ? "person.slash" : "person.fill.checkmark")
            }
            Button {
                model.togglePin(driver.startNumber)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "star.slash" : "star")
            }
            Button {
                model.renameText = model.nicknames[driver.startNumber] ?? ""
                model.isRenaming = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        } label: {
            menuIcon
        }
        .padding(.trailing, 4)
    }

    private var menuIcon: some View {
        Image(systemName: "ellipsis.circle")
            .egFont(23, weight: .semibold)
            .foregroundStyle(Color.egInk)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }

    private var content: some View {
        let route = NavRoute(tab: model.tab, screen: model.screen)
        nav.update(to: route)
        return VStack(spacing: 0) {
            if let backLabel {
                EGBackButton(label: backLabel) {
                    model.goBack()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            ZStack {
                screenContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.egBg)
                    .id(route)
                    .transition(NavTransition(tracker: nav, slides: !reduceMotion))
            }
            .clipped()
        }
        .animation(.snappy(duration: 0.3), value: route)
        // There is no navigation stack to provide the system's edge swipe.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { drag in
                guard model.screen != nil,
                      drag.startLocation.x < 32,
                      drag.translation.width > 70,
                      abs(drag.translation.height) < drag.translation.width
                else { return }
                model.goBack()
            }
        )
    }

    @ViewBuilder
    private var screenContent: some View {
        switch model.screen {
        case .driver(let position):
            DriverDetailView(position: position)
        case .compare(let a, let b):
            CompareView(positionA: a, positionB: b)
        case .leaderboard(let courseID):
            LeaderboardView(courseID: courseID)
        case .leaderboardDriver(let courseID, let position):
            LeaderboardDriverView(courseID: courseID, position: position)
        case .acceleration:
            AccelerationView()
        case .accelerationEntry(let id):
            AccelerationEntryView(entryID: id)
        case nil:
            switch model.tab {
            case .live: LiveView(initialOffset: model.liveScrollOffset)
            case .friends: FriendsView()
            case .events: EventsView()
            case .boards: BoardsView()
            case .settings: SettingsView()
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Tab.allCases, id: \.self) { tab in
                Button {
                    model.select(tab: tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .egFont(16, weight: .semibold)
                            .frame(height: 18)
                        Text(tab.label)
                            .egFont(8.5, weight: .heavy)
                            .kerning(0.9)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .padding(.bottom, 4)
                    .foregroundStyle(model.tab == tab ? Color.egRed : Color.egGray)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.egTabBg)
        .overlay(alignment: .top) {
            Color.egDivider.frame(height: 2)
        }
    }
}

private struct NavRoute: Hashable {
    let tab: AppModel.Tab
    let screen: AppModel.Screen?

    // A refresh can move the driver on screen to another position; that is
    // the same page, not a navigation, so positions stay out of the identity.
    init(tab: AppModel.Tab, screen: AppModel.Screen?) {
        self.tab = tab
        self.screen = switch screen {
        case .driver: .driver(0)
        case .compare: .compare(0, 0)
        default: screen
        }
    }

    var depth: Int {
        switch screen {
        case nil: 0
        case .driver, .leaderboard, .acceleration: 1
        case .compare, .leaderboardDriver, .accelerationEntry: 2
        }
    }
}

private enum NavDirection {
    case forward, back, fade
}

// A view being removed animates with the transition it was last rendered
// with, which predates the navigation that removed it. Holding the direction
// in a reference lets the outgoing and incoming views agree on it.
@MainActor
private final class NavTracker {
    private var route: NavRoute?
    private(set) var direction = NavDirection.fade

    func update(to newRoute: NavRoute) {
        guard newRoute != route else { return }
        if let route {
            if newRoute.tab != route.tab {
                direction = .fade
            } else {
                direction = newRoute.depth < route.depth ? .back : .forward
            }
        }
        route = newRoute
    }
}

private struct NavTransition: Transition {
    let tracker: NavTracker
    let slides: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let direction = slides ? tracker.direction : .fade
        let shift: CGFloat = switch direction {
        case .forward: -phase.value
        case .back: phase.value
        case .fade: 0
        }
        content
            .opacity(direction == .fade && !phase.isIdentity ? 0 : 1)
            .visualEffect { view, proxy in
                view.offset(x: proxy.size.width * shift)
            }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
