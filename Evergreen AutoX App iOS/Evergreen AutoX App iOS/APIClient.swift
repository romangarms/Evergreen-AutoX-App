import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let baseURL: URL
    var deviceToken: String?

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

    func createCourse(_ input: LBCourseInput) async throws -> LBCourse {
        try await send("api/leaderboard/courses", method: "POST", json: input)
    }

    func updateCourse(id: Int, _ input: LBCourseInput) async throws -> LBCourse {
        try await send("api/leaderboard/courses/\(id)", method: "PATCH", json: input)
    }

    func deleteCourse(id: Int) async throws {
        let _: Deleted = try await send("api/leaderboard/courses/\(id)", method: "DELETE")
    }

    func createRun(courseID: Int, _ input: LBRunInput) async throws -> LBRun {
        try await send("api/leaderboard/courses/\(courseID)/runs", method: "POST", json: input)
    }

    func deleteRun(id: Int) async throws {
        let _: Deleted = try await send("api/leaderboard/runs/\(id)", method: "DELETE")
    }

    func report(_ input: LBReportInput) async throws {
        let _: Created = try await send("api/leaderboard/reports", method: "POST", json: input)
    }

    func parseTrackAddict(csv: Data) async throws -> TAParsedLog {
        try await send("api/trackaddict/parse", method: "POST", body: csv, contentType: "text/csv")
    }

    private struct Deleted: Decodable { let deleted: Int }
    private struct Created: Decodable { let id: Int }

    private func get<T: Decodable>(_ path: String, session: URLSession = APIClient.session) async throws -> T {
        try await send(path, method: "GET", session: session)
    }

    private func send<T: Decodable, Body: Encodable>(
        _ path: String, method: String, json: Body
    ) async throws -> T {
        try await send(path, method: method, body: JSONEncoder().encode(json), contentType: "application/json")
    }

    private func send<T: Decodable>(
        _ path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        session: URLSession = APIClient.session
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError(message: "Bad URL: \(baseURL)\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let deviceToken {
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(message: Self.errorMessage(data) ?? "Server returned \(http.statusCode) for \(path)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // FastAPI puts a string in `detail` for our own errors and a list of
    // field errors for validation failures.
    private static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String { return detail }
        if let errors = object["detail"] as? [[String: Any]] {
            let messages = errors.compactMap { error -> String? in
                guard let message = error["msg"] as? String else { return nil }
                let field = (error["loc"] as? [Any])?.last.map { "\($0)" }
                return field.map { "\($0): \(message)" } ?? message
            }
            if !messages.isEmpty { return messages.joined(separator: "\n") }
        }
        return nil
    }
}
