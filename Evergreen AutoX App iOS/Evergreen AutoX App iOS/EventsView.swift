import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model

    // Three sections must fit on one screen with the search field, so
    // each shows only its newest few until expanded.
    private static let collapsedCount = 3

    private struct SourceSection: Identifiable {
        let source: EventSource
        let events: [SHEvent]
        var id: EventSource { source }
    }

    private enum Row: Identifiable {
        case month(String)
        case event(SHEvent)

        var id: String {
            switch self {
            case .month(let month): "month-\(month)"
            case .event(let event): "event-\(event.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.events.isEmpty {
                        StatusView()
                    } else if sections.allSatisfy(\.events.isEmpty) {
                        Text("No events match \"\(query)\".")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGrayDark)
                            .padding(24)
                    }
                    ForEach(visibleSections) { section in
                        if section.id != visibleSections.first?.id {
                            Color.egDivider
                                .frame(height: 2)
                                .padding(.horizontal, 16)
                                .padding(.top, 18)
                        }
                        sectionView(section)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await model.loadEvents() }
        }
    }

    private var query: String {
        model.eventSearch.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool { !query.isEmpty }

    private var sections: [SourceSection] {
        EventSource.allCases.map { source in
            SourceSection(source: source, events: model.events.filter { $0.source == source && matches($0) })
        }
    }

    private var visibleSections: [SourceSection] {
        sections.filter { !$0.events.isEmpty }
    }

    // Searching looks through everything; the toggle only shapes browsing.
    private var autoXOnly: Bool {
        model.speedhiveAutoXOnly && model.hasSpeedhiveAutoXEvents && !isSearching
    }

    private func matches(_ event: SHEvent) -> Bool {
        guard isSearching else { return !autoXOnly || AppModel.isAutoX(event) }
        return event.name.localizedCaseInsensitiveContains(query)
            || (event.location?.name?.localizedCaseInsensitiveContains(query) ?? false)
            || (AppModel.eventDate(event.startDate)?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func rows(_ section: SourceSection) -> [Row] {
        let expanded = isSearching || model.expandedEventSources.contains(section.source)
        let events = expanded ? section.events : Array(section.events.prefix(Self.collapsedCount))
        guard expanded, !isSearching, section.source != .trackaddict else {
            return events.map(Row.event)
        }
        var rows: [Row] = []
        var lastMonth: String?
        for event in events {
            if let month = AppModel.eventMonth(event), month != lastMonth {
                rows.append(.month(month))
                lastMonth = month
            }
            rows.append(.event(event))
        }
        return rows
    }

    private func sectionView(_ section: SourceSection) -> some View {
        let expanded = model.expandedEventSources.contains(section.source)
        let expandable = !isSearching && section.events.count > Self.collapsedCount
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(section.source.label.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(1.1)
                    .foregroundStyle(Color.egInk)
                if section.source == .speedhive, !isSearching, model.hasSpeedhiveAutoXEvents {
                    autoXToggle
                } else if let detail = sectionDetail(section.source) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.egGray)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if expandable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expanded {
                                model.expandedEventSources.remove(section.source)
                            } else {
                                model.expandedEventSources.insert(section.source)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(expanded ? "SHOW LESS" : "SHOW ALL \(section.events.count)")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .heavy))
                        }
                    }
                    .buttonStyle(EGChipButtonStyle(tint: .egRed))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(rows(section)) { row in
                switch row {
                case .month(let month):
                    Text(AppModel.monthLabel(month).uppercased())
                        .font(.system(size: 9.5, weight: .heavy))
                        .kerning(0.9)
                        .foregroundStyle(Color.egGray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                case .event(let event):
                    eventRow(event)
                }
            }
        }
    }

    private func sectionDetail(_ source: EventSource) -> String? {
        switch source {
        case .speedhive: model.orgName
        case .gglc: "Golden Gate Lotus Club"
        case .trackaddict: "Leaderboards"
        }
    }

    private var autoXToggle: some View {
        Button {
            model.speedhiveAutoXOnly.toggle()
        } label: {
            HStack(spacing: 6) {
                EGCheckbox(checked: model.speedhiveAutoXOnly, size: 16)
                Text("AUTOX ONLY")
                    .fixedSize()
            }
        }
        .buttonStyle(EGChipButtonStyle())
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.egGray)
            TextField("Search all events", text: $model.eventSearch)
                .font(.system(size: 12.5))
                .autocorrectionDisabled()
            if !model.eventSearch.isEmpty {
                Button {
                    model.eventSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.egGray)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func eventRow(_ event: SHEvent) -> some View {
        let selected = event.id == model.selectedEventID
        return Button {
            model.openEvent(event.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(event))
                        .font(.system(size: 13.5, weight: .heavy))
                        .multilineTextAlignment(.leading)
                    Text(subtitle(event))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.egGray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    EGTag(text: "SELECTED", size: 9)
                        .padding(.trailing, 8)
                } else if event.source != .trackaddict, event.id == model.events.first?.id {
                    EGTag(text: "LATEST", background: .egInk, foreground: .egBg, size: 9)
                        .padding(.trailing, 8)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(selected ? Color.egMeBg : Color.clear)
            .overlay(alignment: .top) {
                Color.egHairline.frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // Most events share a name, so the date is what tells rows apart.
    private func title(_ event: SHEvent) -> String {
        guard event.source != .trackaddict else { return event.name }
        return AppModel.eventDate(event.startDate) ?? event.name
    }

    private func subtitle(_ event: SHEvent) -> String {
        switch event.source {
        case .trackaddict:
            return event.location?.lengthLabel.map { "\($0) course" } ?? "Leaderboard"
        case .gglc:
            return AppModel.eventDate(event.startDate) == nil ? "" : event.name
        case .speedhive:
            let name = AppModel.eventDate(event.startDate) == nil ? nil : event.name
            return [name, event.location?.name].compactMap(\.self).joined(separator: " · ")
        }
    }
}

struct SessionPickerView: View {
    @Environment(AppModel.self) private var model
    let eventID: Int

    private var event: SHEvent? {
        model.events.first { $0.id == eventID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EGBackButton(label: model.tab.label) {
                    model.goBack()
                }

                Text(event?.name ?? "Event")
                    .font(.system(size: 19, weight: .heavy))

                Text("Your pick is remembered — this event opens straight to it next time.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.egGrayDark)

                Text("SESSIONS")
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(1.1)
                    .foregroundStyle(Color.egInk)
                    .padding(.top, 6)

                if model.viewedSessions.isEmpty {
                    if let error = model.viewedSessionsError {
                        VStack(spacing: 10) {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.egGrayDark)
                                .multilineTextAlignment(.center)
                            Button("RETRY") {
                                model.open(screen: .sessions(eventID))
                            }
                            .buttonStyle(EGButtonStyle(kind: .primary))
                        }
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(AppModel.byMostRecent(model.viewedSessions).enumerated()), id: \.element.id) { index, session in
                        sessionRow(session, isFirst: index == 0)
                    }
                }

                if !recentEvents.isEmpty {
                    Color.egHairline
                        .frame(height: 1)
                        .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECENT EVENTS")
                            .font(.system(size: 12, weight: .heavy))
                            .kerning(1.1)
                            .foregroundStyle(Color.egGray)
                        Text("Switch to another event you've opened before.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.egGrayDark)
                    }
                    .padding(.top, 14)

                    VStack(spacing: 0) {
                        ForEach(Array(recentEvents.enumerated()), id: \.element.id) { index, event in
                            recentEventRow(event, isFirst: index == 0)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
                }

                Button {
                    model.select(tab: .events)
                } label: {
                    HStack {
                        Text("BROWSE ALL EVENTS")
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .heavy))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(EGButtonStyle())
                .padding(.top, 14)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentEvents: [SHEvent] {
        Array(model.recentEvents.filter { $0.id != eventID }.prefix(5))
    }

    private func recentEventRow(_ event: SHEvent, isFirst: Bool) -> some View {
        Button {
            model.openEvent(event.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.name)
                        .font(.system(size: 12.5, weight: .heavy))
                        .multilineTextAlignment(.leading)
                    if let date = AppModel.eventDate(event.startDate) {
                        Text(date)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.egGray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                if !isFirst { Color.egHairline.frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: SHSession, isFirst: Bool) -> some View {
        let selected = eventID == model.selectedEventID && session.id == model.selectedSessionID
        return Button {
            model.pickSession(eventID: eventID, sessionID: session.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.sessionLabel(session, eventName: event?.name))
                        .font(.system(size: 13, weight: .heavy))
                        .multilineTextAlignment(.leading)
                    if let status = session.resultStatus {
                        Text(status)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.egGray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.egRed)
                }
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.egCard)
            .overlay {
                Rectangle().strokeBorder(Color.egDivider, lineWidth: 2)
            }
            .padding(.top, isFirst ? 0 : -2)
        }
        .buttonStyle(.plain)
    }
}
