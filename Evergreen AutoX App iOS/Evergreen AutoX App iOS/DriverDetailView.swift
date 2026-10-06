import SwiftUI

struct DriverDetailView: View {
    @Environment(AppModel.self) private var model
    let position: Int
    @State private var pickingMe = false

    var body: some View {
        if let driver = model.driver(at: position) {
            detail(driver)
        } else {
            StatusView()
        }
    }

    private func detail(_ driver: Driver) -> some View {
        @Bindable var model = model
        let nickname = model.nicknames[driver.startNumber]
        let isMe = driver.startNumber == model.meNumber

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(nickname ?? driver.name)
                            .egFont(24, weight: .heavy)
                            .lineLimit(2)
                        if isMe {
                            EGTag(text: "ME", background: .egInk, foreground: .egBg, size: 9)
                        }
                        if model.pins.contains(driver.startNumber) {
                            Image(systemName: "star.fill")
                                .egFont(13)
                                .foregroundStyle(Color.egRed)
                        }
                    }
                    if nickname != nil {
                        Text(driver.name)
                            .egFont(12)
                            .foregroundStyle(Color.egGrayDark)
                    }
                    HStack(spacing: 6) {
                        if let carClass = driver.carClass {
                            EGTag(text: carClass, size: 10)
                        }
                        EGOutlineTag(text: "CAR #\(driver.startNumber)")
                    }
                    .padding(.top, 4)
                }

                if model.isRenaming {
                    HStack(spacing: 8) {
                        TextField("Nickname", text: $model.renameText)
                            .egFont(13)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.egCard)
                            .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
                            .onSubmit { saveRename(driver) }
                        Button("SAVE") { saveRename(driver) }
                            .buttonStyle(EGButtonStyle(kind: .primary))
                    }
                }

                statsGrid(driver)

                if !isMe {
                    Button("COMPARE VS ME") {
                        if let me = model.me {
                            model.open(screen: .compare(me.position, driver.position))
                        } else {
                            pickingMe = true
                        }
                    }
                    .buttonStyle(EGButtonStyle(kind: .primary))
                }

                runsTable(driver)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $pickingMe) {
            EGSheetFrame(
                title: "Which driver is you?",
                subtitle: "Tap yourself to compare with \(model.displayName(driver)). Change it later from the ⋯ menu on any driver."
            ) {
                VStack(spacing: 0) {
                    ForEach(model.drivers) { candidate in
                        ResultRowView(driver: candidate, showsPin: false) {
                            model.meNumber = candidate.startNumber
                            pickingMe = false
                            if candidate.position != driver.position {
                                model.open(screen: .compare(candidate.position, driver.position))
                            }
                        }
                    }
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private func saveRename(_ driver: Driver) {
        model.setNickname(model.renameText, for: driver.startNumber)
        model.isRenaming = false
    }

    private func statsGrid(_ driver: Driver) -> some View {
        let classCount = model.classCount(driver.carClass)
        var rows: [[(String, String, Color)]] = [
            [
                ("BEST", driver.bestString, .egRed),
                ("IN CLASS", driver.positionInClass.map { "P\($0) / \(classCount)" } ?? "—", .egInk),
                ("OVERALL", "P\(driver.position) / \(model.drivers.count)", .egInk),
            ],
            [
                ("AVERAGE", driver.average.map { LapTime.format($0) } ?? "—", .egInk),
                ("SPREAD", driver.spread.map { String(format: "%.2fs", $0) } ?? "—", .egInk),
                ("RUNS", "\(driver.runs.count)", .egInk),
            ],
        ]
        if let official = driver.officialBest, let number = driver.officialRunNumber {
            rows.append([("OFFICIAL BEST (R\(number), GGLC SCORED)", LapTime.format(official), .egInk)])
        }
        return EGStatsGrid(rows: rows)
    }

    private func runsTable(_ driver: Driver) -> some View {
        DriverRunsTable(driver: driver, runDetail: { run in
            run.number == driver.officialRunNumber ? "OFFICIAL BEST" : nil
        })
    }
}

struct EGStatsGrid: View {
    let rows: [[(String, String, Color)]]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, stats in
                if index > 0 {
                    Color.egDivider.frame(height: 2)
                }
                statRow(stats)
            }
        }
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
    }

    private func statRow(_ stats: [(String, String, Color)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Color.egDivider.frame(width: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    EGColumnLabel(text: stat.0, size: 9)
                    Text(stat.1)
                        .egFont(16, weight: .heavy)
                        .monospacedDigit()
                        .foregroundStyle(stat.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DriverRunsTable: View {
    let driver: Driver
    var runDetail: ((Run) -> String?)?
    var canDelete: ((Run) -> Bool)?
    var onDelete: ((Run) -> Void)?
    var onReport: ((Run) -> Void)?
    var canBlock: ((Run) -> Bool)?
    var onBlock: ((Run) -> Void)?

    private var hasMenu: Bool { onReport != nil || onDelete != nil }
    private var showsSpeed: Bool { driver.runs.contains { $0.speed != nil } }

    var body: some View {
        Section {
            rows
        } header: {
            columnLabels
        }
    }

    private var columnLabels: some View {
        HStack(spacing: 0) {
            EGColumnLabel(text: "RUN").egWidth(44, alignment: .leading)
            EGColumnLabel(text: "TIME").frame(maxWidth: .infinity, alignment: .leading)
            if showsSpeed {
                EGColumnLabel(text: "MPH").egWidth(52, alignment: .trailing)
            }
            EGColumnLabel(text: "Δ BEST").egWidth(66, alignment: .trailing)
            if hasMenu {
                Color.clear.frame(width: 30, height: 1)
            }
        }
        .padding(.vertical, 6)
        .background(Color.egBg.padding(.horizontal, -16))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if driver.runs.isEmpty {
                Text("No runs recorded yet.")
                    .egFont(12)
                    .foregroundStyle(Color.egGrayDark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            ForEach(driver.runs) { run in
                let isBest = !run.dnf && run.seconds == driver.best
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("R\(run.number)")
                            .egFont(12, weight: .heavy)
                            .egWidth(44, alignment: .leading)
                        Text(run.timeString)
                            .egFont(13, weight: isBest ? .heavy : .regular)
                            .monospacedDigit()
                            .foregroundStyle(isBest ? Color.egRed : run.dnf ? Color.egGray : Color.egInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if showsSpeed {
                            Text(run.speed.map { String(format: "%.1f", $0) } ?? "—")
                                .egFont(12)
                                .monospacedDigit()
                                .foregroundStyle(Color.egGrayDark)
                                .egWidth(52, alignment: .trailing)
                        }
                        Text(deltaString(run))
                            .egFont(12, weight: isBest ? .heavy : .regular)
                            .monospacedDigit()
                            .foregroundStyle(isBest ? Color.egRed : Color.egGray)
                            .egWidth(66, alignment: .trailing)
                        if hasMenu {
                            runMenu(run)
                        }
                    }
                    if let detail = detail(run) {
                        Text(detail)
                            .egFont(9.5)
                            .foregroundStyle(Color.egGray)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, isBest ? 6 : 0)
                .background(isBest ? Color.egPinnedBg : Color.clear)
                .padding(.horizontal, isBest ? -6 : 0)
                .overlay(alignment: .top) {
                    Color.egHairline.frame(height: 1)
                }
            }
        }
    }

    private func runMenu(_ run: Run) -> some View {
        Menu {
            if let onDelete, canDelete?(run) ?? true {
                Button(role: .destructive) {
                    onDelete(run)
                } label: {
                    Label("Delete Run", systemImage: "trash")
                }
            }
            if let onReport {
                Button {
                    onReport(run)
                } label: {
                    Label("Report Run", systemImage: "flag")
                }
            }
            if let onBlock, canBlock?(run) ?? true {
                Button(role: .destructive) {
                    onBlock(run)
                } label: {
                    Label("Block Poster", systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .egFont(12, weight: .heavy)
                .foregroundStyle(Color.egGray)
                .frame(width: 30, height: 28, alignment: .trailing)
                .contentShape(Rectangle())
        }
    }

    private func detail(_ run: Run) -> String? {
        let cones = run.cones == 0 ? nil : run.cones == 1 ? "+1 cone" : "+\(run.cones) cones"
        let parts = [runDetail?(run), cones].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func deltaString(_ run: Run) -> String {
        guard let best = driver.best, !run.dnf else { return "" }
        if run.seconds == best { return "BEST" }
        return "+" + String(format: "%.3f", run.seconds - best)
    }
}
