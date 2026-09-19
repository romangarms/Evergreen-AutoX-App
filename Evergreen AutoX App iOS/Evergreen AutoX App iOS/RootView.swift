import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        case nil:
            switch model.tab {
            case .live:
                // Many events share a name, so the date is what says which one
                // is loaded.
                let sub = AppModel.eventDate(model.selectedEvent?.startDate) ?? sessionName
                return ("LIVE", model.selectedEvent?.name ?? "Evergreen AutoX", sub, true)
            case .friends:
                return ("FRIENDS", "Your people", sessionName, false)
            case .events:
                return ("EVENTS", "Pick an event", nil, false)
            case .settings:
                return ("SETUP", "Settings", nil, false)
            }
        }
    }

    private var header: some View {
        let info = headerInfo
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                EGTag(text: info.tag)
                Text(info.title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.egInk)
                    .lineLimit(1)
            }
            if let sub = info.sub {
                if info.changesEvent {
                    Button {
                        model.select(tab: .events)
                    } label: {
                        HStack(spacing: 8) {
                            Text(sub)
                                .font(.system(size: 11.5, weight: .semibold))
                                .kerning(0)
                                .foregroundStyle(Color.egInk)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Text("CHANGE EVENT")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .heavy))
                            }
                        }
                    }
                    .buttonStyle(EGChipButtonStyle(tint: .egRed))
                    .padding(.top, 6)
                    if model.sessions.count > 1 {
                        sessionMenu
                    }
                } else {
                    Text(sub)
                        .font(.system(size: 11.5))
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.egInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.egGray)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .contentShape(Rectangle())
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
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(Color.egInk)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }

    private var content: some View {
        let route = NavRoute(tab: model.tab, screen: model.screen)
        nav.update(to: route)
        return ZStack {
            screenContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.egBg)
                .id(route)
                .transition(NavTransition(tracker: nav, slides: !reduceMotion))
        }
        .clipped()
        .animation(.snappy(duration: 0.3), value: route)
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
        case nil:
            switch model.tab {
            case .live: LiveView(initialOffset: model.liveScrollOffset)
            case .friends: FriendsView()
            case .events: EventsView()
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
                            .font(.system(size: 16, weight: .semibold))
                            .frame(height: 18)
                        Text(tab.label)
                            .font(.system(size: 8.5, weight: .heavy))
                            .kerning(0.9)
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

    var depth: Int {
        switch screen {
        case nil: 0
        case .driver, .leaderboard: 1
        case .compare, .leaderboardDriver: 2
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
