import Foundation

// What the phone tells the Watch app: which session to follow and whose times
// matter. Shared by both targets. The Watch fetches the results itself, so it
// keeps updating while the phone app is in the background. Nonisolated
// because WCSession hands it over off the main thread.
nonisolated struct WatchContext: Codable, Equatable {
    var baseURL: String
    var eventID: Int?
    var eventDate: String?
    var sessionID: Int?
    var meNumber: String?
    var pins: [String]
    var nicknames: [String: String]

    private static let key = "context"

    var message: [String: Any] {
        (try? JSONEncoder().encode(self)).map { [Self.key: $0] } ?? [:]
    }

    init(
        baseURL: String, eventID: Int?, eventDate: String?, sessionID: Int?,
        meNumber: String?, pins: [String], nicknames: [String: String]
    ) {
        self.baseURL = baseURL
        self.eventID = eventID
        self.eventDate = eventDate
        self.sessionID = sessionID
        self.meNumber = meNumber
        self.pins = pins
        self.nicknames = nicknames
    }

    init?(message: [String: Any]) {
        guard let data = message[Self.key] as? Data,
              let context = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = context
    }

    // The same rule as AppModel.wantsLiveRefresh: only an event from today or
    // yesterday can still be producing times.
    var isLive: Bool {
        guard let start = eventDate,
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)
        else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return start.prefix(10) >= formatter.string(from: yesterday)
    }
}
