import SwiftUI

struct LeaderboardView: View {
    @Environment(AppModel.self) private var model
    let courseID: Int

    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var actionError: String?

    private enum Sheet: Identifiable {
        case newRun(LBCourse)
        case editCourse(LBCourse)
        case report(LBReportTarget, String)

        var id: String {
            switch self {
            case .newRun: "newRun"
            case .editCourse: "editCourse"
            case .report(let target, _): "report-\(target.id)"
            }
        }
    }

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

                    if let description = course?.description {
                        Text(description)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let course {
                        actions(course)
                    }

                    if let notice {
                        Text(notice)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.egRed)
                    }
                    EGErrorText(text: actionError)
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
                    Text("No times yet. Be the first to post one.")
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
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newRun(let course):
                GuidelinesGate { RunFormView(course: course) }
            case .editCourse(let course):
                CourseFormView(editing: course)
            case .report(let target, let subject):
                ReportSheet(target: target, subject: subject) {
                    showNotice("Report sent. Thanks.")
                }
            }
        }
        .confirmationDialog(
            "Delete this leaderboard and every time posted to it?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Leaderboard", role: .destructive) {
                Task {
                    do {
                        try await model.deleteCourse(id: courseID)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func actions(_ course: LBCourse) -> some View {
        HStack(spacing: 8) {
            Button("POST A TIME") {
                sheet = .newRun(course)
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            Spacer()
            Menu {
                if course.isOwner {
                    Button {
                        sheet = .editCourse(course)
                    } label: {
                        Label("Edit Leaderboard", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Leaderboard", systemImage: "trash")
                    }
                }
                Button {
                    sheet = .report(.course(course.id), course.name)
                } label: {
                    Label("Report Leaderboard", systemImage: "flag")
                }
                Button {
                    model.hideCourse(id: course.id)
                } label: {
                    Label("Hide Leaderboard", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(EGChipButtonStyle())
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let distance = course?.distanceMiles {
            parts.append(String(format: "%.2f mile course", distance))
        }
        if let creator = course?.createdBy {
            parts.append("Created by \(creator)")
        } else {
            parts.append("Community leaderboard")
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

    @State private var reportTarget: LBReportTarget?
    @State private var pendingDelete: LBRun?
    @State private var notice: String?
    @State private var actionError: String?

    var body: some View {
        if let driver = model.leaderboardDriver(at: position) {
            detail(driver)
        } else {
            StatusView()
        }
    }

    private func detail(_ driver: Driver) -> some View {
        let course = model.leaderboardDetail?.course
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
                    if let course {
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

                if let notice {
                    Text(notice)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.egRed)
                }
                EGErrorText(text: actionError)

                DriverRunsTable(
                    driver: driver,
                    runDetail: { run in
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
                    },
                    canDelete: { run in
                        lbRunsByID[run.lapNumber]?.isOwner == true || course?.isOwner == true
                    },
                    onDelete: { run in
                        pendingDelete = lbRunsByID[run.lapNumber]
                    },
                    onReport: { run in
                        reportTarget = .run(run.lapNumber)
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target, subject: "\(driver.name)'s run on \(course?.name ?? "this leaderboard")") {
                showNotice("Report sent. Thanks.")
            }
        }
        .confirmationDialog(
            "Delete this run?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { run in
            Button("Delete \(LapTime.format(run.adjustedSeconds))", role: .destructive) {
                Task {
                    do {
                        try await model.deleteRun(id: run.id, courseID: courseID)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
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
