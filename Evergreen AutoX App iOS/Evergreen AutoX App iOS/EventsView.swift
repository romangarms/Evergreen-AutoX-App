import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            searchField
            if let month = model.eventMonthFilter {
                monthFilterBanner(month)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.events.isEmpty {
                        StatusView()
                    } else if filteredEvents.isEmpty {
                        Text(emptyMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGrayDark)
                            .padding(24)
                    }
                    ForEach(filteredEvents) { event in
                        eventRow(event)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .refreshable { await model.loadEvents() }
        }
    }

    private var filteredEvents: [SHEvent] {
        let query = model.eventSearch.trimmingCharacters(in: .whitespaces)
        return model.events.filter { event in
            if let month = model.eventMonthFilter, AppModel.eventMonth(event) != month {
                return false
            }
            guard !query.isEmpty else { return true }
            return event.name.localizedCaseInsensitiveContains(query)
                || (event.location?.name?.localizedCaseInsensitiveContains(query) ?? false)
                || (AppModel.eventDate(event.startDate)?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var emptyMessage: String {
        let query = model.eventSearch.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return "No events match \"\(query)\"."
        }
        if let month = model.eventMonthFilter {
            return "No events in \(AppModel.monthLabel(month))."
        }
        return "No events."
    }

    private func monthFilterBanner(_ month: String) -> some View {
        HStack(spacing: 8) {
            Text("SHOWING \(AppModel.monthLabel(month).uppercased()) ONLY")
                .font(.system(size: 9.5, weight: .heavy))
                .kerning(0.9)
                .foregroundStyle(Color.egGrayDark)
            Spacer()
            Button {
                model.eventMonthFilter = nil
            } label: {
                Text("CLEAR")
                    .font(.system(size: 9.5, weight: .heavy))
                    .kerning(0.9)
                    .foregroundStyle(Color.egRed)
                    .contentShape(Rectangle().inset(by: -14))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.egGray)
            TextField("Search events", text: $model.eventSearch)
                .font(.system(size: 12.5))
                .autocorrectionDisabled()
            if !model.eventSearch.isEmpty {
                Button {
                    model.eventSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.egGrayLight)
                        .contentShape(Rectangle().inset(by: -16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func eventRow(_ event: SHEvent) -> some View {
        Button {
            model.open(screen: .sessions(event.id))
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.name)
                        .font(.system(size: 13.5, weight: .heavy))
                        .multilineTextAlignment(.leading)
                    Text(subtitle(event))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.egGray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if event.id == model.events.first?.id {
                    EGTag(text: "LATEST", size: 9)
                        .padding(.trailing, 8)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(event.id == model.selectedEventID ? Color.egMeBg : Color.clear)
            .overlay(alignment: .top) {
                Color.egHairline.frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ event: SHEvent) -> String {
        [AppModel.eventDate(event.startDate), event.location?.name].compactMap(\.self).joined(separator: " · ")
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
                EGBackButton(label: "EVENTS") {
                    model.goBack()
                    model.tab = .events
                }

                Text(event?.name ?? "Event")
                    .font(.system(size: 19, weight: .heavy))

                Text("Your pick is remembered — the app opens straight to it next time.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.egGrayDark)

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
                    ForEach(Array(model.viewedSessions.enumerated()), id: \.element.id) { index, session in
                        sessionRow(session, isFirst: index == 0)
                    }
                }

                if !recentEvents.isEmpty {
                    Text("RECENT EVENTS")
                        .font(.system(size: 12, weight: .heavy))
                        .kerning(1.1)
                        .foregroundStyle(Color.egGray)
                        .padding(.top, 14)

                    VStack(spacing: 0) {
                        ForEach(Array(recentEvents.enumerated()), id: \.element.id) { index, event in
                            recentEventRow(event, isFirst: index == 0)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
                }
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
            model.open(screen: .sessions(event.id))
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
