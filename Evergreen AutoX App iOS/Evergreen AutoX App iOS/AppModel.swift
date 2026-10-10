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
        didSet { defaults.set(pinsByEvent, forKey: "pinsByEvent") }
    }
    private var nicknamesByEvent: [String: [String: String]] {
        didSet { defaults.set(nicknamesByEvent, forKey: "nicknamesByEvent") }
    }
    private var meNumberByEvent: [String: String] {
        didSet { defaults.set(meNumberByEvent, forKey: "meNumberByEvent") }
    }

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
        migrateGlobalPersonalization()
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
            deviceToken: DeviceIdentity.token
        )
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
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)
        else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard start.prefix(10) >= formatter.string(from: yesterday) else { return false }
        return switch screen {
        case nil: tab == .live || tab == .friends
        case .driver, .compare: true
        default: false
        }
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
        compareSelection = []
        friendsScreen = nil
        liveScrollOffset = 0
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
            async let orgTask = client.org(orgID: orgID)
            async let gglcTask = loadGGLCEvents()
            async let leaderboardTask = loadLeaderboardEvents()
            let speedhiveEvents = try await client.events(orgID: orgID)
            let gglcEvents = await gglcTask
            let leaderboardEvents = await leaderboardTask
            events = (speedhiveEvents + gglcEvents)
                .sorted { ($0.startDate ?? "") > ($1.startDate ?? "") }
                + leaderboardEvents
            orgName = (try? await orgTask)?.name
            // Only an event the user opened is remembered; until then every
            // launch follows the newest one. A reload keeps what's on screen.
            let current = events.first { $0.id == selectedEventID }?.id
            if let eventID = current ?? restorableEventID ?? defaultEventID {
                await selectEvent(eventID, remember: false)
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
                    location: SHLocation(name: "Golden Gate Lotus Club", lengthLabel: nil),
                    source: .gglc
                )
            }
        }
    }

    // Like GGLC, leaderboard failures only cost the extra rows.
    private func loadLeaderboardEvents() async -> [SHEvent] {
        let courses = (try? await client.leaderboardCourses()) ?? []
        leaderboardCourses = courses
        return courses
            .filter { !hiddenCourseIDs.contains($0.id) }
            .map(Self.leaderboardEvent)
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
        let leaderboardEvents = await loadLeaderboardEvents()
        events = events.filter { $0.source != .leaderboard } + leaderboardEvents
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
        leaderboardError = nil
        leaderboardDetail = nil
        Task {
            do {
                let detail = try await client.leaderboardCourse(id: courseID)
                guard case .some(.leaderboard(courseID)) = screen else { return }
                leaderboardDetail = detail
            } catch {
                guard case .some(.leaderboard(courseID)) = screen else { return }
                leaderboardError = error.localizedDescription
            }
        }
    }

    // The last list stays up while it reloads; the board changes rarely.
    private func loadAcceleration() {
        accelerationError = nil
        Task {
            do {
                accelerationEntries = try await client.acceleration()
            } catch {
                accelerationError = error.localizedDescription
            }
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
                : try await client.sessions(eventID: eventID)
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
            let loaded = try await client.drivers(sessionID: sessionID)
            guard selectedSessionID == sessionID else { return }
            show(loaded)
        } catch {
            guard selectedSessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // The automatic reload: no spinner, and a failure leaves the last results
    // up rather than replacing a live board with an error every few seconds.
    func refreshSessionData() async {
        lastSessionLoad = .now
        guard let sessionID = selectedSessionID, !isLoading else { return }
        // Speedhive adds sessions through the day; GGLC has only the one.
        if let eventID = selectedEventID, eventID > 0,
           let fetched = try? await client.sessions(eventID: eventID),
           selectedEventID == eventID, fetched != sessions {
            sessions = fetched
        }
        guard let loaded = try? await client.drivers(sessionID: sessionID),
              selectedSessionID == sessionID
        else { return }
        show(loaded)
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
    }

    func pickSession(_ sessionID: Int) {
        guard sessionID != selectedSessionID else { return }
        switchToLive()
        isLoading = true
        Task { await selectSession(sessionID) }
    }
}
