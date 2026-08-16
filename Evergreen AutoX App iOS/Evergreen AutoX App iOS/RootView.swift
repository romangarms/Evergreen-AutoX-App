import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
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
                model.eventMonthFilter = nil
                Task { await model.loadEvents() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Events are pulled from this organization ID. Leave empty for Evergreen Speedway.")
        }
    }

    private var headerInfo: (tag: String, title: String, sub: String?, switchable: Bool) {
        let sessionName = model.selectedSession.map { model.sessionLabel($0) }
        switch model.screen {
        case .driver(let position):
            let driver = model.driver(at: position)
            return ("DRIVER", driver.map { "P\($0.position) — #\($0.startNumber)" } ?? "Driver", sessionName, false)
        case .compare:
            return ("VS", "Head-to-head", sessionName, false)
        case .sessions:
            return ("EVENT", "Pick a session", nil, false)
        case .leaderboard(let courseID):
            let course = model.leaderboardCourses.first { $0.id == courseID }
            return ("LEADERBOARD", course?.name ?? "TrackAddict", nil, false)
        case .leaderboardDriver(let courseID, let position):
            let course = model.leaderboardCourses.first { $0.id == courseID }
            let driver = model.leaderboardDriver(at: position)
            return ("DRIVER", driver?.name ?? "Driver", course?.name, false)
        case nil:
            switch model.tab {
            case .live:
                // GGLC events all share one name, so without the date the header
                // can't show which one is loaded.
                var parts = [sessionName].compactMap(\.self)
                if let event = model.selectedEvent, event.source == .gglc,
                   let date = AppModel.eventDate(event.startDate) {
                    parts.append(date)
                }
                let sub = parts.isEmpty ? nil : parts.joined(separator: " · ") + " · tap to switch"
                return ("LIVE", model.selectedEvent?.name ?? "Evergreen AutoX", sub, true)
            case .friends:
                return ("FRIENDS", "Your people", sessionName, false)
            case .events:
                return ("EVENTS", model.eventsHeaderTitle, nil, false)
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
                if info.switchable {
                    Button {
                        if let eventID = model.selectedEventID {
                            // With one session the picker would instantly bounce
                            // back to Live, making recent events unreachable.
                            model.open(screen: .sessions(eventID), autoPickSingleSession: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sub)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .heavy))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.egGrayDark)
                        .contentShape(Rectangle().inset(by: -13))
                    }
                    .buttonStyle(.plain)
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
            if model.tab == .events, model.screen == nil {
                eventsMenu
            }
        }
        .overlay(alignment: .bottom) {
            Color.egDivider.frame(height: 2)
        }
    }

    private var eventsMenu: some View {
        @Bindable var model = model
        return Menu {
            Button {
                orgIDText = model.orgIDString
                showOrgPrompt = true
            } label: {
                Label("Set Organization ID…", systemImage: "building.2")
            }
            Picker("Filter by Month", selection: $model.eventMonthFilter) {
                Text("All Months").tag(String?.none)
                ForEach(model.eventMonths, id: \.self) { month in
                    Text(AppModel.monthLabel(month)).tag(String?.some(month))
                }
            }
            .pickerStyle(.menu)
            Picker("Filter by Source", selection: $model.eventSourceFilter) {
                Text("All Sources").tag(EventSource?.none)
                ForEach(EventSource.allCases, id: \.self) { source in
                    Text(source.label).tag(EventSource?.some(source))
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(model.eventMonthFilter == nil && model.eventSourceFilter == nil ? Color.egInk : Color.egRed)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .driver(let position):
            DriverDetailView(position: position)
        case .compare(let a, let b):
            CompareView(positionA: a, positionB: b)
        case .sessions(let eventID):
            SessionPickerView(eventID: eventID)
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

#Preview {
    RootView()
        .environment(AppModel())
}
