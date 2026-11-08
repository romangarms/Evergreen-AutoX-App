import Foundation
import Observation

@Observable
final class AppModel {
    enum Tab: String, CaseIterable {
        case live, friends, events, boards, settings

        var label: String {
            switch self {
            case .live: "LIVE"
            case .friends: "FRIENDS"
            case .events: "EVENTS"
            case .boards: "BOARDS"
            case .settings: "SETUP"
            }
        }

        var icon: String {
            switch self {
            case .live: "waveform.path.ecg"
            case .friends: "person.2"
            case .events: "calendar"
            case .boards: "list.number"
            case .settings: "gearshape"
            }
        }
    }

    enum Screen: Hashable {
        case driver(Int)
        case compare(Int, Int)
        case leaderboard(Int)
        case leaderboardDriver(Int, Int)
        case acceleration
        case accelerationEntry(Int)
    }

    static let defaultOrgID = 151294

    // GGLC events have no Speedhive ID, so they get -yyyymmdd — negative so
    // they can never collide with a real Speedhive event ID.
    static func gglcEventID(date: String) -> Int? {
        Int(date.replacingOccurrences(of: "-", with: "")).map { -$0 }
    }

    // Leaderboard courses share the negative ID space with GGLC's -yyyymmdd,
    // so they're offset past any representable date.
    static func leaderboardEventID(courseID: Int) -> Int {
        -(1_000_000_000 + courseID)
    }

    static func leaderboardCourseID(eventID: Int) -> Int {
        -eventID - 1_000_000_000
    }

    private let defaults = UserDefaults.standard

    var tab: Tab = .live
    var screen: Screen?
    private var friendsScreen: Screen?

    var liveScrollOffset: CGFloat = 0
    var eventSearch = ""
    var liveSearch = ""
    var expandedEventSources: Set<EventSource> = []
    var speedhiveAutoXOnly: Bool {
        didSet { defaults.set(speedhiveAutoXOnly, forKey: "speedhiveAutoXOnly") }
    }
    var liveSortByClass: Bool {
        didSet { defaults.set(liveSortByClass, forKey: "liveSortByClass") }
    }
    var orgName: String?
    var events: [SHEvent] = []
    var leaderboardCourses: [LBCourse] = []
    var leaderboardDetail: LBCourseDetail?
    var leaderboardError: String?
    var blocks: [LBBlock] = []
    var submissions: [Submission] = []
    var account: Account?
    var accelerationEntries: [AccelEntry]?
    var accelerationError: String?
    var sessions: [SHSession] = []
    var drivers: [Driver] = []
    var selectedEventID: Int?
    var selectedSessionID: Int?

    var isLoading = false
    var errorMessage: String?

    // When what a page shows was fetched, and whether the latest try to
    // replace it failed, which is when the page says its data is old.
    struct DataAge: Equatable {
        var fetchedAt: Date
        var refreshFailed = false
    }
    var eventsAge: DataAge?
    var boardsAge: DataAge?
    var driversAge: DataAge?
    var leaderboardAge: DataAge?
    var accelerationAge: DataAge?
    var isRetrying = false

    static let liveRefreshInterval: TimeInterval = 10
    @ObservationIgnored private(set) var lastSessionLoad = Date.distantPast

    var compareSelection: [String] = []
    var isRenaming = false
    var renameText = ""

    static let defaultBaseURL = "https://autox.romangarms.com"

    var devMode: Bool {
        didSet { defaults.set(devMode, forKey: "devMode") }
    }
    var customBaseURLString: String {
        didSet { defaults.set(customBaseURLString, forKey: "serverBaseURL") }
    }
    var baseURLString: String {
        let custom = customBaseURLString.trimmingCharacters(in: .whitespaces)
        return devMode && !custom.isEmpty ? custom : Self.defaultBaseURL
    }
    var orgIDString: String {
        didSet { defaults.set(orgIDString, forKey: "orgID") }
    }
    // The name last posted with, offered as the default next time. Only the
    // account's username also sets it, so every post has to refresh it or a
    // typo would stick.
    var posterName: String {
        didSet { defaults.set(posterName, forKey: "posterName") }
    }
    var acceptedGuidelines: Bool {
        didSet { defaults.set(acceptedGuidelines, forKey: "acceptedGuidelines") }
    }
    // Boards this device chose not to see; the server never learns about it.
    private(set) var hiddenCourseIDs: Set<Int> {
        didSet { defaults.set(hiddenCourseIDs.sorted(), forKey: "hiddenCourseIDs") }
    }
    private var pinsByEvent: [String: [String]] {
        didSet {
            defaults.set(pinsByEvent, forKey: "pinsByEvent")
            refreshFollowedNames()
            schedulePushSync()
        }
    }
    private var nicknamesByEvent: [String: [String: String]] {
        didSet { defaults.set(nicknamesByEvent, forKey: "nicknamesByEvent") }
    }
    private var meNumberByEvent: [String: String] {
        didSet {
            defaults.set(meNumberByEvent, forKey: "meNumberByEvent")
            refreshFollowedNames()
            schedulePushSync()
        }
    }

    // New-time notifications. The server is told the ME car and pins of each
    // event from yesterday on, plus the names last marked so it can follow
    // those people into an event this phone hasn't opened yet.
    var notifyMe: Bool {
        didSet {
            defaults.set(notifyMe, forKey: "notifyMe")
            schedulePushSync()
        }
    }
    var notifyFriends: Bool {
        didSet {
            defaults.set(notifyFriends, forKey: "notifyFriends")
            schedulePushSync()
        }
    }
    var wantsNotifications: Bool { notifyMe || notifyFriends }
    // Handed over by the app delegate each launch once iOS registers.
    var pushToken: String? {
        didSet { if pushToken != oldValue { schedulePushSync() } }
    }
    private var followedMeName: String? {
        didSet { defaults.set(followedMeName, forKey: "followedMeName") }
    }
    private var followedFriendNames: [String] {
        didSet { defaults.set(followedFriendNames, forKey: "followedFriendNames") }
    }
    private enum PushSync: Equatable {
        case off
        case on(PushSetup)
    }
    @ObservationIgnored private var sentPush: PushSync?
    @ObservationIgnored private var pushSyncTask: Task<Void, Never>?
    // An event a tapped notification asked for before the events had loaded.
    @ObservationIgnored private var pendingEventID: Int?

    // Car numbers repeat across events, so pins/nicknames/ME are scoped to the
    // selected event rather than stored globally.
    private var eventKey: String? { selectedEventID.map(String.init) }

    var pins: Set<String> {
        get { eventKey.flatMap { pinsByEvent[$0] }.map(Set.init) ?? [] }
        set {
            guard let key = eventKey else { return }
            if newValue.isEmpty {
                pinsByEvent.removeValue(forKey: key)
            } else {
                pinsByEvent[key] = newValue.sorted()
            }
        }
    }
    var nicknames: [String: String] {
        get { eventKey.flatMap { nicknamesByEvent[$0] } ?? [:] }
        set {
            guard let key = eventKey else { return }
            if newValue.isEmpty {
                nicknamesByEvent.removeValue(forKey: key)
            } else {
                nicknamesByEvent[key] = newValue
            }
        }
    }
    var meNumber: String? {
        get { eventKey.flatMap { meNumberByEvent[$0] } }
        set {
            guard let key = eventKey else { return }
            meNumberByEvent[key] = newValue
        }
    }
    private var mePromptDismissedEvents: [String] {
        didSet { defaults.set(mePromptDismissedEvents, forKey: "mePromptDismissedEvents") }
    }
    private var sessionChoice: [String: Int] {
        didSet { defaults.set(sessionChoice, forKey: "sessionChoice") }
    }

    init() {
        devMode = defaults.bool(forKey: "devMode")
        liveSortByClass = defaults.bool(forKey: "liveSortByClass")
        speedhiveAutoXOnly = defaults.object(forKey: "speedhiveAutoXOnly") as? Bool ?? true
        customBaseURLString = defaults.string(forKey: "serverBaseURL") ?? ""
        orgIDString = defaults.string(forKey: "orgID") ?? ""
        posterName = defaults.string(forKey: "posterName") ?? ""
        acceptedGuidelines = defaults.bool(forKey: "acceptedGuidelines")
        hiddenCourseIDs = Set((defaults.array(forKey: "hiddenCourseIDs") as? [Int]) ?? [])
        pinsByEvent = (defaults.dictionary(forKey: "pinsByEvent") as? [String: [String]]) ?? [:]
        nicknamesByEvent = (defaults.dictionary(forKey: "nicknamesByEvent") as? [String: [String: String]]) ?? [:]
        meNumberByEvent = (defaults.dictionary(forKey: "meNumberByEvent") as? [String: String]) ?? [:]
        mePromptDismissedEvents = defaults.stringArray(forKey: "mePromptDismissedEvents") ?? []
        sessionChoice = (defaults.dictionary(forKey: "sessionChoice") as? [String: Int]) ?? [:]
        notifyMe = defaults.bool(forKey: "notifyMe")
        notifyFriends = defaults.bool(forKey: "notifyFriends")
        followedMeName = defaults.string(forKey: "followedMeName")
        followedFriendNames = defaults.stringArray(forKey: "followedFriendNames") ?? []
        migrateGlobalPersonalization()
        ResponseCache.shared.prune(olderThan: .now.addingTimeInterval(-60 * 24 * 60 * 60))
    }

    private func migrateGlobalPersonalization() {
        let legacyPins = defaults.stringArray(forKey: "pins")
        let legacyNicknames = defaults.dictionary(forKey: "nicknames") as? [String: String]
        let legacyMe = defaults.string(forKey: "meNumber")
        guard legacyPins != nil || legacyNicknames != nil || legacyMe != nil else { return }
        if let eventID = defaults.object(forKey: "selectedEventID") as? Int {
            let key = String(eventID)
            if let legacyPins, !legacyPins.isEmpty { pinsByEvent[key] = legacyPins }
            if let legacyNicknames, !legacyNicknames.isEmpty { nicknamesByEvent[key] = legacyNicknames }
            if let legacyMe { meNumberByEvent[key] = legacyMe }
        }
        defaults.removeObject(forKey: "pins")
        defaults.removeObject(forKey: "nicknames")
        defaults.removeObject(forKey: "meNumber")
    }

    private var client: APIClient {
        APIClient(
            baseURL: URL(string: baseURLString.hasSuffix("/") ? baseURLString : baseURLString + "/") ?? URL(filePath: "/"),
            deviceToken: DeviceIdentity.token,
            cache: .shared
        )
    }

    // Asks the server, or when it can't be reached, takes the answer it gave
    // last time.
    private func fetch<T>(_ load: (APIClient) async throws -> T) async throws -> (value: T, age: DataAge) {
        let client = client
        do {
            return (try await load(client), DataAge(fetchedAt: .now))
        } catch {
            guard APIClient.isUnreachable(error), let saved = await client.fromCache(load) else { throw error }
            return (saved.value, DataAge(fetchedAt: saved.date, refreshFailed: true))
        }
    }

    // A list built from several answers is as old as its oldest one.
    private static func combined(_ ages: [DataAge?]) -> DataAge? {
        let ages = ages.compactMap { $0 }
        guard let oldest = ages.map(\.fetchedAt).min() else { return nil }
        return DataAge(fetchedAt: oldest, refreshFailed: ages.contains { $0.refreshFailed })
    }

    var staleSince: Date? {
        let age: DataAge? = switch screen {
        case .driver, .compare: driversAge
        case .leaderboard, .leaderboardDriver: leaderboardAge
        case .acceleration, .accelerationEntry: accelerationAge
        case nil:
            switch tab {
            case .live, .friends: driversAge
            case .events: eventsAge
            case .boards: boardsAge
            case .settings: nil
            }
        }
        return age?.refreshFailed == true ? age?.fetchedAt : nil
    }

    static func staleLabel(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    func retryStale() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        switch screen {
        case .leaderboard(let courseID), .leaderboardDriver(let courseID, _):
            await fetchLeaderboard(courseID: courseID)
        case .acceleration, .accelerationEntry:
            await fetchAcceleration()
        case .driver, .compare, nil:
            if tab == .boards {
                await refreshLeaderboardEvents()
            } else if eventsAge?.refreshFailed == true || tab == .events {
                await loadEvents()
            } else {
                await loadSessionData()
            }
        }
    }

    // Like the custom server URL, a custom org only applies in dev mode, so
    // nobody is left on an org they have no visible way to change.
    var orgID: Int {
        guard devMode else { return Self.defaultOrgID }
        return Int(orgIDString.trimmingCharacters(in: .whitespaces)) ?? Self.defaultOrgID
    }

    var leaderboardEntries: [LBEntry] {
        guard let detail = leaderboardDetail else { return [] }
        return Dictionary(grouping: detail.runs, by: LBEntry.groupKey)
            .values
            .compactMap { runs in
                runs.min { $0.adjustedSeconds < $1.adjustedSeconds }.map { (best: $0, runs: runs) }
            }
            .sorted {
                ($0.best.adjustedSeconds, $0.best.driver, $0.best.vehicle ?? "")
                    < ($1.best.adjustedSeconds, $1.best.driver, $1.best.vehicle ?? "")
            }
            .enumerated()
            .map { index, group in
                LBEntry(rank: index + 1, best: group.best, runs: group.runs)
            }
    }

    func leaderboardEntry(at position: Int) -> LBEntry? {
        leaderboardEntries.first { $0.id == position }
    }

    func leaderboardDriver(at position: Int) -> Driver? {
        leaderboardEntry(at: position)?.driver
    }

    var selectedEvent: SHEvent? { events.first { $0.id == selectedEventID } }

    // The Speedhive org also times oval racing; only its autocross events
    // carry "AutoX" in the name.
    static func isAutoX(_ event: SHEvent) -> Bool {
        event.source != .speedhive || event.name.localizedCaseInsensitiveContains("autox")
    }
    var hasSpeedhiveAutoXEvents: Bool {
        events.contains { $0.source == .speedhive && Self.isAutoX($0) }
    }

    // `events` is newest-first, so each `first` is that source's latest.
    var latestAutoXEventID: Int? {
        events.first { $0.source != .leaderboard && Self.isAutoX($0) }?.id
    }

    // The org's newest Speedhive event is usually an oval race night, which
    // means nothing to an autocrosser opening the app for the first time.
    private var defaultEventID: Int? {
        (events.first { $0.source == .gglc }
            ?? events.first { $0.source == .speedhive && Self.isAutoX($0) }
            ?? events.first { $0.source != .leaderboard })?.id
    }

    // An oval race night hidden by the AutoX-only filter isn't reopened on
    // launch, even if it was the last event viewed.
    private var restorableEventID: Int? {
        guard let saved = defaults.object(forKey: "selectedEventID") as? Int,
              let event = events.first(where: { $0.id == saved }),
              !speedhiveAutoXOnly || Self.isAutoX(event)
        else { return nil }
        return event.id
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

    // Only an event from today or yesterday can still be producing times, and
    // only these pages show them.
    var wantsLiveRefresh: Bool {
        guard let event = selectedEvent, event.source != .leaderboard,
              let start = event.startDate,
              let yesterday = Self.yesterday,
              start.prefix(10) >= yesterday
        else { return false }
        return switch screen {
        case nil: tab == .live || tab == .friends
        case .driver, .compare: true
        default: false
        }
    }
    // yyyy-MM-dd, comparable with an event's startDate.
    static var yesterday: String? {
        guard let date = Calendar.current.date(byAdding: .day, value: -1, to: .now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    var me: Driver? { meNumber.flatMap(driver(number:)) }

    // Car numbers are per event, so the prompt comes back for each new event
    // until it's answered or dismissed there.
    var showsMePrompt: Bool {
        guard let key = eventKey, !drivers.isEmpty else { return false }
        return meNumber == nil && !mePromptDismissedEvents.contains(key)
    }

    func dismissMePrompt() {
        guard let key = eventKey, !mePromptDismissedEvents.contains(key) else { return }
        mePromptDismissedEvents.append(key)
    }
    var friends: [Driver] {
        (me.map { [$0] } ?? []) + drivers.filter { pins.contains($0.startNumber) && $0.startNumber != meNumber }
    }

    func driver(at position: Int) -> Driver? {
        drivers.first { $0.position == position }
    }

    func driver(number: String) -> Driver? {
        drivers.first { $0.startNumber == number }
    }

    func displayName(_ driver: Driver) -> String {
        nicknames[driver.startNumber] ?? driver.name
    }

    // The list people paste into their car group chats, fastest first.
    var friendsShareText: String {
        var title = "\(selectedEvent?.name ?? "AutoX") Leaderboard"
        if let date = Self.shortEventDate(selectedEvent?.startDate) {
            title += " (\(date))"
        }
        let lines = friends.sorted { $0.position < $1.position }.map { driver in
            var name = displayName(driver)
            if name != driver.name { name += " (\(driver.name))" }
            let car = ["#\(driver.startNumber)", driver.vehicle].compactMap(\.self).joined(separator: ", ")
            return "\(name) (\(car)) - \(driver.best.map(LapTime.format) ?? "no time")"
        }
        return ([title] + lines).joined(separator: "\n")
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

    static func shortEventDate(_ dateString: String?) -> String? {
        guard let dateString else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(dateString.prefix(10))) else { return nil }
        parser.dateFormat = "M/d/yy"
        return parser.string(from: date)
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

    func open(screen: Screen) {
        isRenaming = false
        self.screen = screen
        if case .leaderboard(let courseID) = screen {
            loadLeaderboard(courseID: courseID)
        } else if screen == .acceleration {
            loadAcceleration()
        }
    }

    func openEvent(_ eventID: Int) {
        guard let event = events.first(where: { $0.id == eventID }) else { return }
        if event.source == .leaderboard {
            open(screen: .leaderboard(Self.leaderboardCourseID(eventID: eventID)))
            return
        }
        if eventID == selectedEventID, !drivers.isEmpty {
            showLive()
            return
        }
        switchToLive()
        sessions = []
        selectedSessionID = nil
        isLoading = true
        Task { await selectEvent(eventID) }
    }

    private func showLive() {
        screen = nil
        tab = .live
        isRenaming = false
    }

    private func switchToLive() {
        showLive()
        // Stale rows from the old session would make a failed load look like
        // the switch never happened, especially between same-named events.
        drivers = []
        driversAge = nil
        compareSelection = []
        friendsScreen = nil
        liveScrollOffset = 0
        liveSearch = ""
    }

    func goBack() {
        isRenaming = false
        switch screen {
        case .leaderboardDriver(let courseID, _): screen = .leaderboard(courseID)
        case .accelerationEntry: screen = .acceleration
        default: screen = nil
        }
    }

    func togglePin(_ number: String) {
        if pins.contains(number) {
            pins.remove(number)
        } else {
            pins.insert(number)
        }
        compareSelection = compareSelection.filter { pins.contains($0) || $0 == meNumber }
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
        pinsByEvent = [:]
        nicknamesByEvent = [:]
        meNumberByEvent = [:]
        mePromptDismissedEvents = []
        compareSelection = []
    }

    func start() async {
        guard events.isEmpty else { return }
        async let accountTask: Void = loadAccount()
        await loadEvents()
        await accountTask
    }

    func loadEvents() async {
        isLoading = true
        errorMessage = nil
        do {
            let orgID = orgID
            async let orgTask = fetch { try await $0.org(orgID: orgID) }
            async let gglcTask = loadGGLCEvents()
            async let leaderboardTask = loadLeaderboardEvents()
            let speedhive = try await fetch { try await $0.events(orgID: orgID) }
            let gglc = await gglcTask
            let leaderboard = await leaderboardTask
            let leaderboardEvents = leaderboard?.events ?? events.filter { $0.source == .leaderboard }
            events = (speedhive.value + gglc.events)
                .sorted { ($0.startDate ?? "") > ($1.startDate ?? "") }
                + leaderboardEvents
            eventsAge = Self.combined([speedhive.age, gglc.age])
            if let leaderboard { boardsAge = leaderboard.age }
            orgName = (try? await orgTask)?.value.name
            // Event dates decide which marks the server is told about.
            schedulePushSync()
            let notified = pendingEventID.flatMap { id in events.first { $0.id == id }?.id }
            pendingEventID = nil
            // Only an event the user opened is remembered; until then every
            // launch follows the newest one. A reload keeps what's on screen.
            let current = events.first { $0.id == selectedEventID }?.id
            if let notified {
                switchToLive()
                await selectEvent(notified)
            } else if let eventID = current ?? restorableEventID ?? defaultEventID {
                await selectEvent(eventID, remember: false)
            } else {
                isLoading = false
            }
        } catch {
            errorMessage = error.localizedDescription
            eventsAge?.refreshFailed = true
            isLoading = false
        }
    }

    // GGLC failures only cost the extra events; Speedhive stays usable.
    private func loadGGLCEvents() async -> (events: [SHEvent], age: DataAge?) {
        let year = Calendar.current.component(.year, from: .now)
        async let current = fetch { try await $0.gglcEvents(year: year) }
        async let previous = fetch { try await $0.gglcEvents(year: year - 1) }
        let years = [try? await current, try? await previous].compactMap { $0 }
        let stubs = years.flatMap(\.value)
        let events = stubs.compactMap { stub in
            Self.gglcEventID(date: stub.date).map {
                SHEvent(
                    id: $0,
                    name: "GGLC Autocross",
                    startDate: stub.date,
                    location: SHLocation(name: "Golden Gate Lotus Club", lengthLabel: nil),
                    source: .gglc
                )
            }
        }
        return (events, Self.combined(years.map(\.age)))
    }

    // Like GGLC, leaderboard failures only cost the extra rows. Nil means
    // nothing came back, so the boards already shown stay.
    private func loadLeaderboardEvents() async -> (events: [SHEvent], age: DataAge)? {
        guard let courses = try? await fetch({ try await $0.leaderboardCourses() }) else {
            boardsAge?.refreshFailed = true
            return nil
        }
        leaderboardCourses = courses.value
        let events = courses.value
            .filter { !hiddenCourseIDs.contains($0.id) }
            .map(Self.leaderboardEvent)
        return (events, courses.age)
    }

    private static func leaderboardEvent(_ course: LBCourse) -> SHEvent {
        SHEvent(
            id: leaderboardEventID(courseID: course.id),
            name: course.name,
            startDate: nil,
            location: SHLocation(
                name: course.createdBy.map { "by \($0)" },
                lengthLabel: course.distanceMiles.map { String(format: "%.2f mi", $0) }
            ),
            source: .leaderboard
        )
    }

    func refreshLeaderboardEvents() async {
        guard let leaderboard = await loadLeaderboardEvents() else { return }
        events = events.filter { $0.source != .leaderboard } + leaderboard.events
        boardsAge = leaderboard.age
    }

    var ownedCourseCount: Int { leaderboardCourses.count { $0.isOwner } }
    var hiddenCourseCount: Int { hiddenCourseIDs.count }

    func createCourse(_ input: LBCourseInput) async throws {
        let course = try await client.createCourse(input)
        await refreshLeaderboardEvents()
        open(screen: .leaderboard(course.id))
        tab = .boards
    }

    func updateCourse(id: Int, _ input: LBCourseInput) async throws {
        _ = try await client.updateCourse(id: id, input)
        await refreshLeaderboardEvents()
        loadLeaderboard(courseID: id)
    }

    func deleteCourse(id: Int) async throws {
        try await client.deleteCourse(id: id)
        await refreshLeaderboardEvents()
        leaveLeaderboard(id)
    }

    func joinCourse(code: String) async throws {
        let course = try await client.joinCourse(code: code)
        hiddenCourseIDs.remove(course.id)
        await refreshLeaderboardEvents()
        open(screen: .leaderboard(course.id))
        tab = .boards
    }

    func leaveCourse(id: Int) async throws {
        try await client.leaveCourse(id: id)
        await refreshLeaderboardEvents()
        leaveLeaderboard(id)
    }

    func hideCourse(id: Int) {
        hiddenCourseIDs.insert(id)
        events.removeAll { $0.id == Self.leaderboardEventID(courseID: id) }
        leaveLeaderboard(id)
    }

    func unhideAllCourses() {
        hiddenCourseIDs = []
        Task { await refreshLeaderboardEvents() }
    }

    private func leaveLeaderboard(_ courseID: Int) {
        switch screen {
        case .leaderboard(courseID), .leaderboardDriver(courseID, _):
            screen = nil
            tab = .boards
        default:
            break
        }
    }

    func addRun(courseID: Int, _ input: LBRunInput) async throws {
        _ = try await client.createRun(courseID: courseID, input)
        loadLeaderboard(courseID: courseID)
    }

    // Ranks shift after a deletion, so the driver page being viewed may no
    // longer be the same person; the board is the only safe place to land.
    func deleteRun(id: Int, courseID: Int) async throws {
        try await client.deleteRun(id: id)
        screen = .leaderboard(courseID)
        loadLeaderboard(courseID: courseID)
    }

    func report(_ target: LBReportTarget, reason: String) async throws {
        try await client.report(LBReportInput(target: target, reason: reason))
    }

    // The server stops sending anything the blocked poster owns, so the open
    // board is reloaded, or left if it was theirs.
    func blockPoster(_ target: LBReportTarget, courseID: Int) async throws {
        let block = try await client.block(LBBlockInput(target: target))
        blocks.removeAll { $0.id == block.id }
        blocks.insert(block, at: 0)
        await refreshLeaderboardEvents()
        if leaderboardCourses.contains(where: { $0.id == courseID }) {
            switch screen {
            case .leaderboard(courseID), .leaderboardDriver(courseID, _):
                screen = .leaderboard(courseID)
                loadLeaderboard(courseID: courseID)
            default:
                break
            }
        } else {
            leaveLeaderboard(courseID)
        }
    }

    func addAcceleration(_ input: AccelEntryInput) async throws {
        _ = try await client.createAcceleration(input)
        loadAcceleration()
    }

    func deleteAcceleration(id: Int) async throws {
        try await client.deleteAcceleration(id: id)
        accelerationEntries?.removeAll { $0.id == id }
        screen = .acceleration
        loadAcceleration()
    }

    func deleteOtherAccelerationRun(id: Int) async throws {
        try await client.deleteAcceleration(id: id)
        loadAcceleration()
    }

    func blockAccelerationPoster(entryID: Int) async throws {
        let block = try await client.block(LBBlockInput(target: .acceleration(entryID)))
        blocks.removeAll { $0.id == block.id }
        blocks.insert(block, at: 0)
        accelerationEntries?.removeAll { $0.id == entryID }
        screen = .acceleration
        loadAcceleration()
        await refreshLeaderboardEvents()
    }

    func unblock(id: Int) async throws {
        try await client.unblock(id: id)
        blocks.removeAll { $0.id == id }
        await refreshLeaderboardEvents()
    }

    var signedIn: Bool { account?.signedIn == true }
    // Apple often shares no name, and the server will not take posts from an
    // account without one.
    var needsUsername: Bool { signedIn && (account?.name ?? "").isEmpty }

    func loadAccount() async {
        if let loaded = try? await client.account() {
            account = loaded
        }
    }

    func signIn(identityToken: String, nonce: String, authorizationCode: String?, name: String?) async throws {
        account = try await client.signInWithApple(
            AppleSignInInput(identityToken: identityToken, nonce: nonce, authorizationCode: authorizationCode, name: name)
        )
        if posterName.isEmpty, let name = account?.name {
            posterName = name
        }
        await refreshOwnership()
    }

    func updateAccountName(_ name: String) async throws {
        account = try await client.updateAccount(name: name)
        if let name = account?.name {
            posterName = name
        }
    }

    func signOut() async throws {
        account = try await client.signOut()
        await refreshOwnership()
    }

    func deleteAccount() async throws {
        account = try await client.deleteAccount()
        await refreshOwnership()
    }

    // Signing in or out changes which boards, runs and blocks the server
    // counts as this device's, so whatever is on screen is refetched. A board
    // that went with the account is left.
    private func refreshOwnership() async {
        await refreshLeaderboardEvents()
        await loadBlocks()
        await loadSubmissions()
        if accelerationEntries != nil {
            loadAcceleration()
        }
        switch screen {
        case .leaderboard(let courseID), .leaderboardDriver(let courseID, _):
            guard leaderboardCourses.contains(where: { $0.id == courseID }) else {
                leaveLeaderboard(courseID)
                return
            }
            if let detail = try? await client.leaderboardCourse(id: courseID), leaderboardDetail?.course.id == courseID {
                leaderboardDetail = detail
            }
        default:
            break
        }
    }

    func loadBlocks() async {
        if let loaded = try? await client.blocks() {
            blocks = loaded
        }
    }

    func loadSubmissions() async {
        if let loaded = try? await client.submissions() {
            submissions = loaded
        }
    }

    func submit(_ input: SubmissionInput) async throws {
        let submission = try await client.submit(input)
        submissions.insert(submission, at: 0)
    }

    func deleteSubmission(id: Int) async throws {
        try await client.deleteSubmission(id: id)
        submissions.removeAll { $0.id == id }
    }

    func parseTrackAddict(csv: Data) async throws -> [TALap] {
        try await client.parseTrackAddict(csv: csv).laps
    }

    private func loadLeaderboard(courseID: Int) {
        leaderboardDetail = nil
        leaderboardAge = nil
        Task { await fetchLeaderboard(courseID: courseID) }
    }

    func fetchLeaderboard(courseID: Int) async {
        leaderboardError = nil
        func stillOpen() -> Bool {
            switch screen {
            case .leaderboard(courseID), .leaderboardDriver(courseID, _): true
            default: false
            }
        }
        do {
            let detail = try await fetch { try await $0.leaderboardCourse(id: courseID) }
            guard stillOpen() else { return }
            leaderboardDetail = detail.value
            leaderboardAge = detail.age
        } catch {
            guard stillOpen() else { return }
            leaderboardError = error.localizedDescription
            leaderboardAge?.refreshFailed = true
        }
    }

    // The last list stays up while it reloads; the board changes rarely.
    private func loadAcceleration() {
        Task { await fetchAcceleration() }
    }

    func fetchAcceleration() async {
        accelerationError = nil
        do {
            let entries = try await fetch { try await $0.acceleration() }
            accelerationEntries = entries.value
            accelerationAge = entries.age
        } catch {
            accelerationError = error.localizedDescription
            accelerationAge?.refreshFailed = true
        }
    }

    // Speedhive lists sessions grouped by class, not by time, so "first"
    // is usually a morning practice.
    static func latestSession(_ sessions: [SHSession]) -> SHSession? {
        sessions.max { ($0.startTime ?? "") < ($1.startTime ?? "") }
    }

    static func byMostRecent(_ sessions: [SHSession]) -> [SHSession] {
        sessions.sorted { ($0.startTime ?? "") > ($1.startTime ?? "") }
    }

    private static func gglcSessions(eventID: Int) -> [SHSession] {
        [SHSession(id: eventID, name: "Results", type: nil, startTime: nil, resultStatus: nil)]
    }

    // Loads overlap when the user taps around faster than the network; after
    // every await, a load whose event or session is no longer the selected
    // one stops without touching state.
    func selectEvent(_ eventID: Int, remember: Bool = true) async {
        selectedEventID = eventID
        if remember {
            defaults.set(eventID, forKey: "selectedEventID")
        }
        isLoading = true
        errorMessage = nil
        do {
            let fetched = eventID < 0
                ? Self.gglcSessions(eventID: eventID)
                : try await fetch { try await $0.sessions(eventID: eventID) }.value
            guard selectedEventID == eventID else { return }
            sessions = fetched
            let saved = sessionChoice[String(eventID)]
            let sessionID = sessions.first { $0.id == saved }?.id ?? Self.latestSession(sessions)?.id
            if let sessionID {
                await selectSession(sessionID)
            } else {
                drivers = []
                isLoading = false
            }
        } catch {
            guard selectedEventID == eventID else { return }
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
        lastSessionLoad = .now
        do {
            let loaded = try await fetch { try await $0.drivers(sessionID: sessionID) }
            guard selectedSessionID == sessionID else { return }
            show(loaded.value)
            driversAge = loaded.age
        } catch {
            guard selectedSessionID == sessionID else { return }
            errorMessage = error.localizedDescription
            driversAge?.refreshFailed = true
        }
        isLoading = false
    }

    // Pulling down on a results page. With nothing showing, the event may
    // have gained its first session since it was opened, so it is reopened.
    func reloadResults() async {
        if drivers.isEmpty, let eventID = selectedEventID {
            await selectEvent(eventID, remember: false)
        } else if selectedEventID == nil {
            await loadEvents()
        } else {
            await loadSessionData()
        }
    }

    // The automatic reload: no spinner, and a failure leaves the last results
    // up, marked as old, rather than replacing a live board with an error.
    func refreshSessionData() async {
        lastSessionLoad = .now
        guard !isLoading else { return }
        // Speedhive adds sessions through the day; GGLC has only the one.
        if let eventID = selectedEventID, eventID > 0,
           let fetched = try? await client.sessions(eventID: eventID),
           selectedEventID == eventID, fetched != sessions {
            sessions = fetched
            if selectedSessionID == nil {
                selectedSessionID = Self.latestSession(fetched)?.id
            }
        }
        guard let sessionID = selectedSessionID else { return }
        let loaded = try? await client.drivers(sessionID: sessionID)
        guard selectedSessionID == sessionID else { return }
        guard let loaded else {
            driversAge?.refreshFailed = true
            return
        }
        show(loaded)
        driversAge = DataAge(fetchedAt: .now)
        errorMessage = nil
    }

    // Screens name a driver by position, which a new time can change while
    // the page is open, so an open page follows its driver's car number.
    private func show(_ loaded: [Driver]) {
        func moved(_ position: Int) -> Int {
            guard let number = driver(at: position)?.startNumber else { return position }
            return loaded.first { $0.startNumber == number }?.position ?? position
        }
        func following(_ screen: Screen?) -> Screen? {
            switch screen {
            case .driver(let position): .driver(moved(position))
            case .compare(let a, let b): .compare(moved(a), moved(b))
            default: screen
            }
        }
        let (newScreen, newFriendsScreen) = (following(screen), following(friendsScreen))
        if newScreen != screen { screen = newScreen }
        friendsScreen = newFriendsScreen
        drivers = loaded
        refreshFollowedNames()
    }

    func openNotifiedEvent(_ eventID: Int) {
        if events.contains(where: { $0.id == eventID }) {
            openEvent(eventID)
        } else {
            pendingEventID = eventID
        }
    }

    // Names come from the open event, the only one with drivers loaded, and
    // only when it has marks; otherwise the last marked names stay, unless
    // nothing is marked anywhere.
    private func refreshFollowedNames() {
        guard !drivers.isEmpty else { return }
        guard me != nil || !pins.isEmpty else {
            if meNumberByEvent.isEmpty && pinsByEvent.isEmpty {
                setFollowedNames(me: nil, friends: [])
            }
            return
        }
        let friends = drivers
            .filter { pins.contains($0.startNumber) && $0.startNumber != meNumber }
            .map(\.name)
        setFollowedNames(me: me?.name, friends: friends.sorted())
    }

    private func setFollowedNames(me: String?, friends: [String]) {
        guard me != followedMeName || friends != followedFriendNames else { return }
        followedMeName = me
        followedFriendNames = friends
        schedulePushSync()
    }

    private var pushWatches: [PushSetup.Watch] {
        guard let yesterday = Self.yesterday else { return [] }
        let watches = events.compactMap { event -> PushSetup.Watch? in
            guard event.source != .leaderboard,
                  let date = event.startDate.map({ String($0.prefix(10)) }),
                  date >= yesterday
            else { return nil }
            let key = String(event.id)
            let me = meNumberByEvent[key]
            let friends = (pinsByEvent[key] ?? []).filter { $0 != me }
            guard me != nil || !friends.isEmpty else { return nil }
            return PushSetup.Watch(eventID: event.id, eventDate: date, me: me, friends: friends)
        }
        // The server takes at most 10; `events` is newest first.
        return Array(watches.prefix(10))
    }

    // Changes come in bursts (a pin, then the names it changes), so they
    // settle for a second and go as one request, and only when it differs
    // from what the server already has.
    func schedulePushSync() {
        pushSyncTask?.cancel()
        pushSyncTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await syncPush()
        }
    }

    private func syncPush() async {
        let wanted: PushSync
        if wantsNotifications {
            guard let pushToken else { return }
            #if DEBUG
            let environment = "sandbox"
            #else
            let environment = "production"
            #endif
            wanted = .on(PushSetup(
                apnsToken: pushToken,
                environment: environment,
                notifyMe: notifyMe,
                notifyFriends: notifyFriends,
                meName: followedMeName,
                friendNames: followedFriendNames,
                watches: pushWatches
            ))
        } else {
            // A phone that never turned them on has nothing to take back.
            guard sentPush != nil || defaults.bool(forKey: "pushRegistered") else { return }
            wanted = .off
        }
        guard wanted != sentPush else { return }
        do {
            switch wanted {
            case .off: _ = try await client.clearPush()
            case .on(let setup): _ = try await client.setPush(setup)
            }
            sentPush = wanted
            defaults.set(wanted != .off, forKey: "pushRegistered")
        } catch {
            // Sent again with the next change or launch.
        }
    }

    func pickSession(_ sessionID: Int) {
        guard sessionID != selectedSessionID else { return }
        switchToLive()
        isLoading = true
        Task { await selectSession(sessionID) }
    }
}
