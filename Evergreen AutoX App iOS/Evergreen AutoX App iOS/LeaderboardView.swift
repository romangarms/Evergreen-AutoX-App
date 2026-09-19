import SwiftUI

struct LeaderboardView: View {
    @Environment(AppModel.self) private var model
    let courseID: Int

    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var actionError: String?
    @State private var width: CGFloat = 0

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
        let entries = model.leaderboardEntries
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
                } else if entries.isEmpty {
                    Text("No times yet. Be the first to post one.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.egGray)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                } else {
                    let layout = LBRowLayout(
                        wide: width >= LBRowLayout.wideThreshold,
                        showsRaw: entries.contains { $0.best.legacy }
                    )
                    LBColumnHeader(layout: layout)
                        .padding(.top, 10)
                    ForEach(entries) { entry in
                        LBEntryRow(entry: entry, layout: layout) {
                            model.open(screen: .leaderboardDriver(courseID, entry.id))
                        }
                    }
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        if let entry = model.leaderboardEntry(at: position) {
            detail(entry)
        } else {
            StatusView()
        }
    }

    private func detail(_ entry: LBEntry) -> some View {
        let driver = entry.driver
        let course = model.leaderboardDetail?.course
        let lbRuns = entry.runs
        let otherCars = model.leaderboardEntries.filter { $0.best.driver == driver.name && $0.id != entry.id }
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

                if !otherCars.isEmpty {
                    let layout = LBRowLayout(wide: false, showsRaw: false)
                    VStack(alignment: .leading, spacing: 0) {
                        EGColumnLabel(text: "OTHER CARS")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        ForEach(otherCars) { other in
                            LBEntryRow(entry: other, layout: layout) {
                                model.open(screen: .leaderboardDriver(courseID, other.id))
                            }
                        }
                    }
                    .padding(.horizontal, -16)
                    .padding(.top, 6)
                }
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

// Thresholds and colors match the HWY 9 sheet's conditional formatting, which
// the web leaderboard also copies, so a run reads the same in all three.
enum LBTint {
    case green, lightGreen, yellow, orange, red, day, gray

    var color: Color {
        switch self {
        case .green: Color(hex: 0x57BB8A)
        case .lightGreen: Color(hex: 0xA4D3A2)
        case .yellow: Color(hex: 0xFFD54F)
        case .orange: Color(hex: 0xF6A45B)
        case .red: Color(hex: 0xE57373)
        case .day: Color(hex: 0xF1C232)
        case .gray: Color(hex: 0x9E9E9E)
        }
    }

    // Deliberately non-adaptive: the tints stay the same in both modes.
    static let ink = Color(hex: 0x1A1A1A)

    static func hp(_ hp: Int?) -> LBTint? {
        guard let hp else { return nil }
        if hp >= 300 { return .green }
        if hp > 200 { return .yellow }
        if hp > 150 { return .orange }
        return .red
    }

    static func conditions(_ value: String?) -> LBTint? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "dry": .green
        case "wet": .orange
        case "day": .day
        case "dark": .gray
        default: nil
        }
    }
}

struct LBRowLayout {
    static let wideThreshold: CGFloat = 700

    let wide: Bool
    let showsRaw: Bool

    let rank: CGFloat = 30
    let time: CGFloat = 70
    let hp: CGFloat = 42
    let speed: CGFloat = 44
    let driver: CGFloat = 72
    let date: CGFloat = 62
    let conditions: CGFloat = 44
    let chevron: CGFloat = 10
}

struct LBColumnHeader: View {
    let layout: LBRowLayout

    var body: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "POS").frame(width: layout.rank, alignment: .leading)
            EGColumnLabel(text: layout.wide && layout.showsRaw ? "ADJ. TIME" : "TIME")
                .frame(width: layout.time, alignment: .trailing)
            if layout.wide, layout.showsRaw {
                EGColumnLabel(text: "RAW TIME").frame(width: layout.time, alignment: .trailing)
            }
            EGColumnLabel(text: "HP").frame(width: layout.hp)
            EGColumnLabel(text: layout.wide ? "VEHICLE" : "VEHICLE · DRIVER")
                .frame(maxWidth: .infinity, alignment: .leading)
            if layout.wide {
                EGColumnLabel(text: "AVG").frame(width: layout.speed, alignment: .trailing)
                EGColumnLabel(text: "TOP").frame(width: layout.speed, alignment: .trailing)
                EGColumnLabel(text: "DRIVER").frame(width: layout.driver, alignment: .leading)
                EGColumnLabel(text: "DATE").frame(width: layout.date, alignment: .trailing)
            }
            EGColumnLabel(text: "COND").frame(width: layout.conditions)
            Color.clear.frame(width: layout.chevron, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct LBEntryRow: View {
    let entry: LBEntry
    let layout: LBRowLayout
    let onTap: () -> Void

    private static let podium = [
        Color(light: 0xB8860B, dark: 0xF2C14E),
        Color(light: 0x8A8A8A, dark: 0xC0C0C0),
        Color(light: 0xA0622A, dark: 0xCD7F32),
    ]

    private static let runDateParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private var best: LBRun { entry.best }

    var body: some View {
        Button(action: onTap) {
            // fixedSize makes the row settle on its tallest cell's height and
            // then offer that to every cell, so the tinted ones fill the row.
            HStack(spacing: 8) {
                Text("P\(entry.id)")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(entry.id <= 3 ? Self.podium[entry.id - 1] : Color.egInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: layout.rank, alignment: .leading)
                timeCell
                if layout.wide, layout.showsRaw {
                    LBTintCell(
                        text: best.legacy ? best.time : "—",
                        tint: best.legacy ? .lightGreen : nil
                    )
                    .frame(width: layout.time)
                }
                LBTintCell(text: best.hp.map(String.init) ?? "—", tint: LBTint.hp(best.hp))
                    .frame(width: layout.hp)
                vehicleCell
                if layout.wide {
                    speedCell(best.avgSpeedMph)
                    speedCell(best.topSpeedMph)
                    Text(best.driver)
                        .font(.system(size: 12, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: layout.driver, alignment: .leading)
                    Text(shortDate ?? "—")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.egGrayDark)
                        .frame(width: layout.date, alignment: .trailing)
                }
                LBTintCell(text: best.conditions ?? "—", tint: LBTint.conditions(best.conditions))
                    .frame(width: layout.conditions)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
                    .frame(width: layout.chevron)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.egInk)
        .overlay(alignment: .top) {
            Color.egHairline.frame(height: 1)
        }
    }

    private var timeCell: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(best.adjustedTime)
                .font(.system(size: 14, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if best.legacy, !layout.wide {
                Text(best.time)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LBTint.ink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(LBTint.lightGreen.color)
            }
        }
        .frame(width: layout.time, alignment: .trailing)
    }

    private var vehicleCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(best.vehicle ?? best.driver)
                .font(.system(size: 13, weight: .heavy))
                .lineLimit(2)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.egGray)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speedCell(_ mph: Double?) -> some View {
        Text(mph.map { String(format: "%.1f", $0) } ?? "—")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Color.egGrayDark)
            .frame(width: layout.speed, alignment: .trailing)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if !layout.wide {
            if best.vehicle != nil { parts.append(best.driver) }
            if let shortDate { parts.append(shortDate) }
        }
        if entry.runs.count > 1 { parts.append("\(entry.runs.count) runs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var shortDate: String? {
        best.runDate
            .flatMap { Self.runDateParser.date(from: $0) }
            .map { $0.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits)) }
    }
}

private struct LBTintCell: View {
    let text: String
    let tint: LBTint?

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: tint == nil ? .regular : .heavy))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(tint == nil ? Color.egGray : LBTint.ink)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint?.color ?? .clear)
    }
}
