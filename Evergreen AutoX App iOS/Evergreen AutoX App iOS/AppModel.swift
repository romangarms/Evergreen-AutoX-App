import Foundation
import Observation

@Observable
final class AppModel {
    enum Tab: String, CaseIterable {
        case live, friends, events, settings

        var label: String {
            switch self {
            case .live: "LIVE"
            case .friends: "FRIENDS"
            case .events: "EVENTS"
            case .settings: "SETUP"
            }
        }

        var icon: String {
            switch self {
            case .live: "waveform.path.ecg"
            case .friends: "person.2"
            case .events: "calendar"
            case .settings: "gearshape"
            }
        }
    }

    enum Screen: Equatable {
        case driver(Int)
        case compare(Int, Int)
        case sessions(Int)
    }

    static let defaultOrgID = 151294

    // GGLC events have no Speedhive ID, so they get -yyyymmdd — negative so
    // they can never collide with a real Speedhive event ID.
    static func gglcEventID(date: String) -> Int? {
        Int(date.replacingOccurrences(of: "-", with: "")).map { -$0 }
    }

    static func gglcDate(eventID: Int) -> String {
        let digits = String(-eventID)
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    private let defaults = UserDefaults.standard

    var tab: Tab = .live
    var screen: Screen?
    private var friendsScreen: Screen?

    var liveScrollOffset: CGFloat = 0
    var eventSearch = ""
    var eventMonthFilter: String?
    var orgName: String?
    var events: [SHEvent] = []
    var sessions: [SHSession] = []
    var viewedSessions: [SHSession] = []
    var drivers: [Driver] = []
    var selectedEventID: Int?
    var selectedSessionID: Int?

    var isLoading = false
    var errorMessage: String?
    var viewedSessionsError: String?

    var compareSelection: [String] = []
    var isRenaming = false
    var renameText = ""

    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: "serverBaseURL") }
    }
    var orgIDString: String {
        didSet { defaults.set(orgIDString, forKey: "orgID") }
    }
    var pins: Set<String> {
        didSet { defaults.set(Array(pins), forKey: "pins") }
    }
    var nicknames: [String: String] {
        didSet { defaults.set(nicknames, forKey: "nicknames") }
    }
    var meNumber: String? {
        didSet { defaults.set(meNumber, forKey: "meNumber") }
    }
    private var sessionChoice: [String: Int] {
        didSet { defaults.set(sessionChoice, forKey: "sessionChoice") }
    }
    private var recentEventIDs: [Int] {
        didSet { defaults.set(recentEventIDs, forKey: "recentEventIDs") }
    }

    init() {
        baseURLString = defaults.string(forKey: "serverBaseURL") ?? "http://127.0.0.1:8321"
        orgIDString = defaults.string(forKey: "orgID") ?? ""
        pins = Set(defaults.stringArray(forKey: "pins") ?? [])
        nicknames = (defaults.dictionary(forKey: "nicknames") as? [String: String]) ?? [:]
        meNumber = defaults.string(forKey: "meNumber")
        sessionChoice = (defaults.dictionary(forKey: "sessionChoice") as? [String: Int]) ?? [:]
        recentEventIDs = (defaults.array(forKey: "recentEventIDs") as? [Int]) ?? []
    }

    private var client: APIClient {
        APIClient(baseURL: URL(string: baseURLString.hasSuffix("/") ? baseURLString : baseURLString + "/") ?? URL(filePath: "/"))
    }

    var orgID: Int {
        Int(orgIDString.trimmingCharacters(in: .whitespaces)) ?? Self.defaultOrgID
    }

    var selectedEvent: SHEvent? { events.first { $0.id == selectedEventID } }
    var recentEvents: [SHEvent] { recentEventIDs.compactMap { id in events.first { $0.id == id } } }
    var eventMonths: [String] {
        Set(events.compactMap { Self.eventMonth($0) }).sorted(by: >)
    }

    static func eventMonth(_ event: SHEvent) -> String? {
        event.startDate.flatMap { $0.count >= 7 ? String($0.prefix(7)) : nil }
    }

    static func monthLabel(_ month: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: month) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }
    var selectedSession: SHSession? { sessions.first { $0.id == selectedSessionID } }
    var me: Driver? { meNumber.flatMap(driver(number:)) }
    var friends: [Driver] { drivers.filter { pins.contains($0.startNumber) } }

    func driver(at position: Int) -> Driver? {
        drivers.first { $0.position == position }
    }

    func driver(number: String) -> Driver? {
        drivers.first { $0.startNumber == number }
    }

    func displayName(_ driver: Driver) -> String {
        nicknames[driver.startNumber] ?? driver.name
    }

    func classCount(_ carClass: String?) -> Int {
        drivers.count { $0.carClass == carClass }
    }

    func gapToMe(_ driver: Driver) -> Double? {
        guard let mine = me?.best, let theirs = driver.best, driver.startNumber != meNumber else { return nil }
        return theirs - mine
    }

    func sessionLabel(_ session: SHSession, eventName: String? = nil) -> String {
        var parts: [String] = []
        let event = eventName ?? selectedEvent?.name
        if let name = session.name, !name.isEmpty, name != event {
            parts.append(name)
        } else if let type = session.type, !type.isEmpty {
            parts.append(type.capitalized)
        }
        if let time = Self.timeOfDay(session.startTime) {
            parts.append(time)
        }
        return parts.isEmpty ? "Session \(session.id)" : parts.joined(separator: " · ")
    }

    static func timeOfDay(_ isoString: String?) -> String? {
        guard let isoString else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: isoString) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func eventDate(_ dateString: String?) -> String? {
        guard let dateString else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateString) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    func select(tab: Tab) {
        if self.tab == tab {
            screen = nil
            if tab == .friends { friendsScreen = nil }
        } else {
            if self.tab == .friends { friendsScreen = screen }
            self.tab = tab
            screen = tab == .friends ? friendsScreen : nil
        }
        isRenaming = false
    }

    func open(screen: Screen, autoPickSingleSession: Bool = true) {
        isRenaming = false
        self.screen = screen
        if case .sessions(let eventID) = screen {
            loadViewedSessions(eventID: eventID, autoPick: autoPickSingleSession)
        }
    }

    func goBack() {
        screen = nil
        isRenaming = false
    }

    func togglePin(_ number: String) {
        if pins.contains(number) {
            pins.remove(number)
        } else {
            pins.insert(number)
        }
        compareSelection = compareSelection.filter(pins.contains)
    }

    func toggleCompareSelection(_ number: String) {
        if let index = compareSelection.firstIndex(of: number) {
            compareSelection.remove(at: index)
        } else {
            compareSelection = Array((compareSelection + [number]).suffix(2))
        }
    }

    func setNickname(_ nickname: String, for number: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: number)
        } else {
            nicknames[number] = trimmed
        }
    }

    func resetPersonalization() {
        pins = []
        nicknames = [:]
        meNumber = nil
        compareSelection = []
    }

    func start() async {
        guard events.isEmpty else { return }
        await loadEvents()
    }

    func loadEvents() async {
        isLoading = true
        errorMessage = nil
        do {
            async let orgTask = client.org(orgID: orgID)
            async let gglcTask = loadGGLCEvents()
            let speedhiveEvents = try await client.events(orgID: orgID)
            let gglcEvents = await gglcTask
            events = (speedhiveEvents + gglcEvents)
                .sorted { ($0.startDate ?? "") > ($1.startDate ?? "") }
            orgName = (try? await orgTask)?.name
            let saved = defaults.object(forKey: "selectedEventID") as? Int
            let eventID = events.first { $0.id == saved }?.id ?? events.first?.id
            if let eventID {
                await selectEvent(eventID)
            } else {
                isLoading = false
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // GGLC failures only cost the extra events; Speedhive stays usable.
    private func loadGGLCEvents() async -> [SHEvent] {
        let year = Calendar.current.component(.year, from: .now)
        async let current = client.gglcEvents(year: year)
        async let previous = client.gglcEvents(year: year - 1)
        let stubs = ((try? await current) ?? []) + ((try? await previous) ?? [])
        return stubs.compactMap { stub in
            Self.gglcEventID(date: stub.date).map {
                SHEvent(
                    id: $0,
                    name: "GGLC Autocross",
                    startDate: stub.date,
                    location: SHLocation(name: "Golden Gate Lotus Club", lengthLabel: nil)
                )
            }
        }
    }

    private static func gglcSessions(eventID: Int) -> [SHSession] {
        [SHSession(id: eventID, name: "Results", type: nil, startTime: nil, resultStatus: nil)]
    }

    private static func gglcDrivers(_ event: GGLCEvent) -> [Driver] {
        let ranked = event.classes
            .flatMap { klass in
                klass.drivers.map { driver in
                    (
                        driver: driver,
                        carClass: driver.carClass.isEmpty ? klass.name : driver.carClass,
                        best: driver.runs.compactMap(\.total).min()
                    )
                }
            }
            .sorted {
                switch ($0.best, $1.best) {
                case let (a?, b?): a < b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): $0.driver.name < $1.driver.name
                }
            }
        var classCounts: [String: Int] = [:]
        return ranked.enumerated().map { index, entry in
            classCounts[entry.carClass, default: 0] += 1
            return Driver(
                position: index + 1,
                gglc: entry.driver,
                carClass: entry.carClass,
                positionInClass: classCounts[entry.carClass]
            )
        }
    }

    private func recordRecentEvent(_ eventID: Int) {
        var ids = recentEventIDs.filter { $0 != eventID }
        ids.insert(eventID, at: 0)
        recentEventIDs = Array(ids.prefix(6))
    }

    func selectEvent(_ eventID: Int) async {
        selectedEventID = eventID
        defaults.set(eventID, forKey: "selectedEventID")
        recordRecentEvent(eventID)
        isLoading = true
        errorMessage = nil
        do {
            sessions = eventID < 0
                ? Self.gglcSessions(eventID: eventID)
                : try await client.sessions(eventID: eventID)
            let saved = sessionChoice[String(eventID)]
            let sessionID = sessions.first { $0.id == saved }?.id ?? sessions.first?.id
            if let sessionID {
                await selectSession(sessionID)
            } else {
                drivers = []
                isLoading = false
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func selectSession(_ sessionID: Int) async {
        selectedSessionID = sessionID
        if let eventID = selectedEventID {
            sessionChoice[String(eventID)] = sessionID
        }
        await loadSessionData()
    }

    func loadSessionData() async {
        guard let sessionID = selectedSessionID else { return }
        isLoading = true
        errorMessage = nil
        do {
            if sessionID < 0 {
                let event = try await client.gglcEvent(date: Self.gglcDate(eventID: sessionID))
                drivers = Self.gglcDrivers(event)
            } else {
                async let resultsTask = client.results(sessionID: sessionID)
                async let lapsTask = client.laps(sessionID: sessionID)
                let (results, lapsRows) = try await (resultsTask, lapsTask)
                let lapsByPosition = Dictionary(lapsRows.compactMap { row in row.position.map { ($0, row.laps ?? []) } }) { first, _ in first }
                drivers = results
                    .map { Driver(result: $0, laps: lapsByPosition[$0.position ?? -1] ?? []) }
                    .sorted { $0.position < $1.position }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadViewedSessions(eventID: Int, autoPick: Bool) {
        viewedSessionsError = nil
        if eventID == selectedEventID {
            viewedSessions = sessions
            if autoPick { autoPickIfOnlyChoice(eventID: eventID) }
            return
        }
        if eventID < 0 {
            viewedSessions = Self.gglcSessions(eventID: eventID)
            if autoPick { autoPickIfOnlyChoice(eventID: eventID) }
            return
        }
        viewedSessions = []
        Task {
            do {
                let fetched = try await client.sessions(eventID: eventID)
                guard case .some(.sessions(eventID)) = screen else { return }
                viewedSessions = fetched
                if autoPick { autoPickIfOnlyChoice(eventID: eventID) }
            } catch {
                guard case .some(.sessions(eventID)) = screen else { return }
                viewedSessionsError = error.localizedDescription
            }
        }
    }

    private func autoPickIfOnlyChoice(eventID: Int) {
        guard viewedSessions.count == 1,
              case .some(.sessions(eventID)) = screen else { return }
        pickSession(eventID: eventID, sessionID: viewedSessions[0].id)
    }

    func pickSession(eventID: Int, sessionID: Int) {
        selectedEventID = eventID
        defaults.set(eventID, forKey: "selectedEventID")
        recordRecentEvent(eventID)
        sessions = viewedSessions
        // Stale rows from the old session would make a failed load look like
        // the switch never happened, especially between same-named events.
        drivers = []
        screen = nil
        tab = .live
        compareSelection = []
        friendsScreen = nil
        liveScrollOffset = 0
        Task { await selectSession(sessionID) }
    }
}
