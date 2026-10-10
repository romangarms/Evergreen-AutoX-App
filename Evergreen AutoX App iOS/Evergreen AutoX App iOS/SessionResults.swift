import Foundation

// Shared with the Watch app, which loads the same results on its own so it
// stays live while the phone is in a pocket.
extension APIClient {
    // GGLC sessions carry the event's -yyyymmdd ID (see AppModel.gglcEventID).
    func drivers(sessionID: Int) async throws -> [Driver] {
        if sessionID < 0 {
            let event = try await gglcEvent(date: Self.gglcDate(eventID: sessionID))
            return Self.gglcDrivers(event)
        }
        async let resultsTask = results(sessionID: sessionID)
        async let lapsTask = laps(sessionID: sessionID)
        let (results, lapsRows) = try await (resultsTask, lapsTask)
        let lapsByPosition = Dictionary(lapsRows.compactMap { row in row.position.map { ($0, row.laps ?? []) } }) { first, _ in first }
        return results
            .map { Driver(result: $0, laps: lapsByPosition[$0.position ?? -1] ?? []) }
            .sorted { $0.position < $1.position }
    }

    static func gglcDate(eventID: Int) -> String {
        let digits = String(-eventID)
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
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
}
