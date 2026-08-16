import SwiftUI

struct LeaderboardView: View {
    @Environment(AppModel.self) private var model
    let courseID: Int

    private var course: LBCourse? {
        model.leaderboardDetail?.course ?? model.leaderboardCourses.first { $0.id == courseID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    EGBackButton(label: "EVENTS") {
                        model.goBack()
                        model.tab = .events
                    }

                    Text(course?.name ?? "Leaderboard")
                        .font(.system(size: 19, weight: .heavy))

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.egGrayDark)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                if model.leaderboardDetail == nil {
                    if let error = model.leaderboardError {
                        VStack(spacing: 10) {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.egGrayDark)
                                .multilineTextAlignment(.center)
                            Button("RETRY") {
                                model.open(screen: .leaderboard(courseID))
                            }
                            .buttonStyle(EGButtonStyle(kind: .primary))
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .padding(24)
                            .frame(maxWidth: .infinity)
                    }
                } else if model.leaderboardDrivers.isEmpty {
                    Text("No runs yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.egGray)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                } else {
                    ResultsColumnHeader(showsNumber: false, showsPin: false)
                        .padding(.top, 10)
                    ForEach(model.leaderboardDrivers) { driver in
                        ResultRowView(driver: driver, showsNumber: false, showsPin: false) {
                            model.open(screen: .leaderboardDriver(courseID, driver.position))
                        }
                    }
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        var parts = ["Times from TrackAddict logs"]
        if let distance = course?.distanceMiles {
            parts.insert(String(format: "%.2f mile course", distance), at: 0)
        }
        if course?.legacyDistanceMiles != nil {
            parts.append("legacy runs scaled to the current course length")
        }
        return parts.joined(separator: " · ")
    }
}

struct LeaderboardDriverView: View {
    @Environment(AppModel.self) private var model
    let courseID: Int
    let position: Int

    var body: some View {
        if let driver = model.leaderboardDriver(at: position) {
            detail(driver)
        } else {
            StatusView()
        }
    }

    private func detail(_ driver: Driver) -> some View {
        let lbRuns = model.leaderboardDetail?.runs.filter { $0.driver == driver.name } ?? []
        let lbRunsByID = Dictionary(lbRuns.map { ($0.id, $0) }) { first, _ in first }
        let avgSpeeds = lbRuns.compactMap(\.avgSpeedMph)
        let avgSpeed = avgSpeeds.isEmpty ? nil : avgSpeeds.reduce(0, +) / Double(avgSpeeds.count)
        let topSpeed = lbRuns.compactMap(\.topSpeedMph).max()

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EGBackButton(label: "LEADERBOARD") {
                    model.screen = .leaderboard(courseID)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(driver.name)
                        .font(.system(size: 24, weight: .heavy))
                        .lineLimit(2)
                    if let course = model.leaderboardDetail?.course {
                        Text(course.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGrayDark)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vehicleTags(lbRuns), id: \.self) { tag in
                            EGOutlineTag(text: tag.uppercased())
                        }
                    }
                    .padding(.top, 4)
                }

                EGStatsGrid(rows: [
                    [
                        ("BEST", driver.bestString, .egRed),
                        ("AVERAGE", driver.average.map { LapTime.format($0) } ?? "—", .egInk),
                        ("SPREAD", driver.spread.map { String(format: "%.2fs", $0) } ?? "—", .egInk),
                    ],
                    [
                        ("AVG MPH", avgSpeed.map { String(format: "%.1f", $0) } ?? "—", .egInk),
                        ("TOP MPH", topSpeed.map { String(format: "%.1f", $0) } ?? "—", .egInk),
                        ("RUNS", "\(driver.runs.count)", .egInk),
                    ],
                ])

                DriverRunsTable(driver: driver) { run in
                    guard let lbRun = lbRunsByID[run.lapNumber] else { return nil }
                    var parts = [
                        lbRun.vehicle,
                        lbRun.conditions,
                        AppModel.eventDate(lbRun.runDate),
                    ].compactMap(\.self)
                    if lbRun.legacy {
                        parts.append("Legacy · raw \(lbRun.time)")
                    }
                    return parts.isEmpty ? nil : parts.joined(separator: " · ")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func vehicleTags(_ lbRuns: [LBRun]) -> [String] {
        var tags: [String] = []
        for run in lbRuns {
            guard let vehicle = run.vehicle else { continue }
            let tag = run.hp.map { "\(vehicle) · \($0) HP" } ?? vehicle
            if !tags.contains(tag) {
                tags.append(tag)
            }
        }
        return tags
    }
}
