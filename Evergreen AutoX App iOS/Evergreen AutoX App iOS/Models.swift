import Foundation

struct SHOrg: Codable {
    let id: Int?
    let name: String?
}

struct SHEvent: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let startDate: String?
    let location: SHLocation?
}

struct SHLocation: Codable, Hashable {
    let name: String?
    let lengthLabel: String?
}

struct SHSession: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let startTime: String?
    let resultStatus: String?
}

struct SHResultRow: Codable {
    let position: Int?
    let name: String?
    let startNumber: String?
    let resultClass: String?
    let bestTime: String?
    let numberOfLaps: Int?
    let positionInClass: Int?
    let bestSpeed: Double?
    let status: String?
}

struct SHLapsRow: Codable {
    let position: Int?
    let laps: [SHLap]?
}

struct SHLap: Codable {
    let lap: Int?
    let lapTime: String?
    let timeOfDay: Double?
    let speed: Double?
}

struct GGLCEventStub: Codable, Hashable {
    let date: String
    let url: String
}

struct GGLCEvent: Codable {
    let date: String
    let url: String
    let title: String
    let updated: String
    let classes: [GGLCClass]
}

struct GGLCClass: Codable {
    let name: String
    let runCount: Int
    let drivers: [GGLCDriver]
}

struct GGLCDriver: Codable {
    let name: String
    let car: String
    let make: String
    let model: String
    let carClass: String
    let indexed: Double?
    let runs: [GGLCRun]
}

struct GGLCRun: Codable {
    let run: Int
    let raw: String
    let time: Double?
    let cones: Int
    let dnf: Bool
    let total: Double?
    let best: Bool
}

enum LapTime {
    static func seconds(from string: String?) -> Double? {
        guard let string, !string.isEmpty else { return nil }
        var total = 0.0
        for part in string.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func format(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.3f", seconds) }
        let minutes = Int(seconds) / 60
        return String(format: "%d:%06.3f", minutes, seconds - Double(minutes * 60))
    }

    static func gap(_ delta: Double) -> String {
        String(format: "%+.2f", delta)
    }
}

struct Run: Identifiable {
    let number: Int
    let lapNumber: Int
    let seconds: Double
    let speed: Double?
    let timeOfDay: Date?

    var id: Int { lapNumber }
    var timeString: String { LapTime.format(seconds) }
}

struct Driver: Identifiable {
    let position: Int
    let name: String
    let startNumber: String
    let carClass: String?
    let positionInClass: Int?
    let runs: [Run]
    private let bestTimeString: String?

    var id: Int { position }

    var best: Double? {
        runs.map(\.seconds).min() ?? LapTime.seconds(from: bestTimeString)
    }

    var bestString: String { best.map(LapTime.format) ?? "—" }

    var average: Double? {
        runs.isEmpty ? nil : runs.map(\.seconds).reduce(0, +) / Double(runs.count)
    }

    var spread: Double? {
        guard let lo = runs.map(\.seconds).min(), let hi = runs.map(\.seconds).max(), runs.count > 1 else { return nil }
        return hi - lo
    }

    // Transponders keep lapping between runs, so a "lap" can be a 3-minute to
    // 90-minute wait in grid. A lap counts as a run only if it's under this
    // ceiling AND under 2x the driver's fastest lap (short queue laps would
    // otherwise slip through and wreck averages).
    static let maxRunSeconds: Double = 300

    // GGLC "total" already includes cone penalties (1s/cone).
    init(position: Int, gglc: GGLCDriver, carClass: String?, positionInClass: Int?) {
        self.position = position
        name = gglc.name.isEmpty ? "(unknown)" : gglc.name
        startNumber = gglc.car.isEmpty ? "P\(position)" : gglc.car
        self.carClass = carClass
        self.positionInClass = positionInClass
        bestTimeString = nil
        runs = gglc.runs.compactMap { run in
            guard let total = run.total else { return nil }
            return Run(number: run.run, lapNumber: run.run, seconds: total, speed: nil, timeOfDay: nil)
        }
    }

    init(result: SHResultRow, laps: [SHLap]) {
        position = result.position ?? 0
        name = result.name ?? "(unknown)"
        startNumber = result.startNumber ?? "P\(result.position ?? 0)"
        carClass = result.resultClass
        positionInClass = result.positionInClass
        bestTimeString = result.bestTime

        let fastest = laps
            .compactMap { LapTime.seconds(from: $0.lapTime) }
            .filter { $0 > 0 && $0 < Self.maxRunSeconds }
            .min()
        let cutoff = fastest.map { min(Self.maxRunSeconds, $0 * 2) } ?? Self.maxRunSeconds

        var runNumber = 0
        runs = laps.compactMap { lap in
            guard let seconds = LapTime.seconds(from: lap.lapTime), seconds > 0, seconds < cutoff else { return nil }
            runNumber += 1
            return Run(
                number: runNumber,
                lapNumber: lap.lap ?? runNumber,
                seconds: seconds,
                speed: lap.speed,
                timeOfDay: lap.timeOfDay.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
    }
}
