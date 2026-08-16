import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let baseURL: URL

    // Short timeouts so an unreachable server fails fast at launch instead of
    // hanging behind URLSession's default 60s.
    private static let session = makeSession(requestTimeout: 8)

    // GGLC pages are scraped on demand server-side; a cold fetch can outlast
    // the fast-fail timeout, and timing out midway leaves stale results up.
    private static let gglcSession = makeSession(requestTimeout: 30)

    private static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func org(orgID: Int) async throws -> SHOrg {
        try await get("api/orgs/\(orgID)")
    }

    func events(orgID: Int, limit: Int = 200) async throws -> [SHEvent] {
        try await get("api/orgs/\(orgID)/events?limit=\(limit)")
    }

    func sessions(eventID: Int) async throws -> [SHSession] {
        try await get("api/events/\(eventID)/sessions")
    }

    func results(sessionID: Int) async throws -> [SHResultRow] {
        try await get("api/sessions/\(sessionID)/results")
    }

    func laps(sessionID: Int) async throws -> [SHLapsRow] {
        try await get("api/sessions/\(sessionID)/laps")
    }

    func gglcEvents(year: Int) async throws -> [GGLCEventStub] {
        try await get("api/gglc/events?year=\(year)", session: Self.gglcSession)
    }

    func gglcEvent(date: String) async throws -> GGLCEvent {
        try await get("api/gglc/events/\(date)", session: Self.gglcSession)
    }

    func leaderboardCourses() async throws -> [LBCourse] {
        try await get("api/leaderboard/courses")
    }

    func leaderboardCourse(id: Int) async throws -> LBCourseDetail {
        try await get("api/leaderboard/courses/\(id)")
    }

    private func get<T: Decodable>(_ path: String, session: URLSession = APIClient.session) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError(message: "Bad URL: \(baseURL)\(path)")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError(message: "Server returned \(http.statusCode) for \(path)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
