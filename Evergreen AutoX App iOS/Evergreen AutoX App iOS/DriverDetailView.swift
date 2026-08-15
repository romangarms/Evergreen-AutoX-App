import SwiftUI

struct DriverDetailView: View {
    @Environment(AppModel.self) private var model
    let position: Int

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
        let pinned = model.pins.contains(driver.startNumber)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EGBackButton(label: model.tab == .friends ? "FRIENDS" : "RESULTS") {
                    model.goBack()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(nickname ?? driver.name)
                            .font(.system(size: 24, weight: .heavy))
                            .lineLimit(2)
                        if isMe {
                            EGTag(text: "ME", background: .egInk, foreground: .egBg, size: 9)
                        }
                    }
                    Text(nickname != nil ? driver.name : "No nickname yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.egGrayDark)
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
                            .font(.system(size: 13))
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
                runsTable(driver)

                HStack(spacing: 8) {
                    Button(pinned ? "UNPIN" : "PIN") {
                        model.togglePin(driver.startNumber)
                    }
                    .buttonStyle(EGButtonStyle())
                    Button("RENAME") {
                        model.renameText = nickname ?? ""
                        model.isRenaming = true
                    }
                    .buttonStyle(EGButtonStyle())
                    if !isMe, let me = model.me {
                        Button("COMPARE VS ME") {
                            model.open(screen: .compare(me.position, driver.position))
                        }
                        .buttonStyle(EGButtonStyle(kind: .primary))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveRename(_ driver: Driver) {
        model.setNickname(model.renameText, for: driver.startNumber)
        model.isRenaming = false
    }

    private func statsGrid(_ driver: Driver) -> some View {
        let classCount = model.classCount(driver.carClass)
        let topStats: [(String, String, Color)] = [
            ("BEST", driver.bestString, .egRed),
            ("AVERAGE", driver.average.map { LapTime.format($0) } ?? "—", .egInk),
            ("SPREAD", driver.spread.map { String(format: "%.2fs", $0) } ?? "—", .egInk),
        ]
        let bottomStats: [(String, String, Color)] = [
            ("IN CLASS", driver.positionInClass.map { "P\($0) / \(classCount)" } ?? "—", .egInk),
            ("OVERALL", "P\(driver.position) / \(model.drivers.count)", .egInk),
            ("RUNS", "\(driver.runs.count)", .egInk),
        ]
        return VStack(spacing: 0) {
            statRow(topStats)
            Color.egDivider.frame(height: 2)
            statRow(bottomStats)
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
                        .font(.system(size: 16, weight: .heavy))
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

    private func runsTable(_ driver: Driver) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EGColumnLabel(text: "RUN").frame(width: 44, alignment: .leading)
                EGColumnLabel(text: "TIME").frame(maxWidth: .infinity, alignment: .leading)
                EGColumnLabel(text: "MPH").frame(width: 52, alignment: .trailing)
                EGColumnLabel(text: "Δ BEST").frame(width: 66, alignment: .trailing)
            }
            .padding(.bottom, 6)

            if driver.runs.isEmpty {
                Text("No runs recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.egGrayDark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            ForEach(driver.runs) { run in
                let isBest = run.seconds == driver.best
                HStack(spacing: 0) {
                    Text("R\(run.number)")
                        .font(.system(size: 12, weight: .heavy))
                        .frame(width: 44, alignment: .leading)
                    Text(run.timeString)
                        .font(.system(size: 13, weight: isBest ? .heavy : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isBest ? Color.egRed : Color.egInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(run.speed.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.egGrayDark)
                        .frame(width: 52, alignment: .trailing)
                    Text(deltaString(run, driver: driver))
                        .font(.system(size: 12, weight: isBest ? .heavy : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isBest ? Color.egRed : Color.egGray)
                        .frame(width: 66, alignment: .trailing)
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

    private func deltaString(_ run: Run, driver: Driver) -> String {
        guard let best = driver.best else { return "" }
        if run.seconds == best { return "BEST" }
        return "+" + String(format: "%.3f", run.seconds - best)
    }
}
