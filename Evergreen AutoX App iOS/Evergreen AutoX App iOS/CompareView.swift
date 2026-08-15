import Charts
import SwiftUI

struct CompareView: View {
    @Environment(AppModel.self) private var model
    let positionA: Int
    let positionB: Int

    var body: some View {
        if let a = model.driver(at: positionA), let b = model.driver(at: positionB) {
            compare(a, b)
        } else {
            StatusView()
        }
    }

    private func compare(_ a: Driver, _ b: Driver) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EGBackButton(label: "BACK") { model.goBack() }

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        EGColumnLabel(text: "#\(a.startNumber) · \(a.carClass ?? "—")", size: 10)
                            .foregroundStyle(Color.egRed)
                        Text(model.displayName(a))
                            .font(.system(size: 16, weight: .heavy))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("VS")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.egGray)
                        .padding(.bottom, 2)
                    VStack(alignment: .trailing, spacing: 1) {
                        EGColumnLabel(text: "#\(b.startNumber) · \(b.carClass ?? "—")", size: 10)
                        Text(model.displayName(b))
                            .font(.system(size: 16, weight: .heavy))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                statGrid(a, b)
                chartSection(a, b)
                runByRun(a, b)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statGrid(_ a: Driver, _ b: Driver) -> some View {
        let rows: [(String, Double?, Double?, (Double) -> String)] = [
            ("BEST", a.best, b.best, LapTime.format),
            ("AVERAGE", a.average, b.average, LapTime.format),
            ("SPREAD", a.spread, b.spread, { String(format: "%.2fs", $0) }),
            ("RUNS", Double(a.runs.count), Double(b.runs.count), { String(Int($0)) }),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let aWins = winner(row.1, over: row.2)
                let bWins = winner(row.2, over: row.1)
                HStack(spacing: 0) {
                    Text(row.1.map(row.3) ?? "—")
                        .font(.system(size: 12.5, weight: aWins ? .heavy : .regular))
                        .monospacedDigit()
                        .foregroundStyle(aWins ? Color.egRed : Color.egInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    EGColumnLabel(text: row.0)
                    Text(row.2.map(row.3) ?? "—")
                        .font(.system(size: 12.5, weight: bWins ? .heavy : .regular))
                        .monospacedDigit()
                        .foregroundStyle(bWins ? Color.egRed : Color.egInk)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if index > 0 { Color.egHairline.frame(height: 1) }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
    }

    private func winner(_ value: Double?, over other: Double?) -> Bool {
        guard let value, let other else { return false }
        return value < other
    }

    private func chartSection(_ a: Driver, _ b: Driver) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EGColumnLabel(text: "TIMES OVER THE DAY")
                Spacer()
                legendItem(color: .egRed, name: model.displayName(a))
                legendItem(color: .egInk, name: model.displayName(b))
            }
            if a.runs.isEmpty && b.runs.isEmpty {
                Text("No runs to chart yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.egGrayDark)
            } else {
                runChart(a, b)
            }
        }
    }

    private func legendItem(color: Color, name: String) -> some View {
        HStack(spacing: 4) {
            color.frame(width: 14, height: 2)
            Text(name)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(Color.egGray)
                .lineLimit(1)
        }
    }

    private func runChart(_ a: Driver, _ b: Driver) -> some View {
        let all = (a.runs + b.runs).map(\.seconds)
        let lo = all.min() ?? 0
        let hi = all.max() ?? 1
        let pad = max((hi - lo) * 0.18, 0.25)

        return Chart {
            ForEach(a.runs) { run in
                LineMark(
                    x: .value("Run", run.number),
                    y: .value("Time", run.seconds),
                    series: .value("Driver", "A")
                )
                .foregroundStyle(Color.egRed)
                PointMark(x: .value("Run", run.number), y: .value("Time", run.seconds))
                    .foregroundStyle(Color.egRed)
                    .symbol(.square)
                    .symbolSize(38)
            }
            ForEach(b.runs) { run in
                LineMark(
                    x: .value("Run", run.number),
                    y: .value("Time", run.seconds),
                    series: .value("Driver", "B")
                )
                .foregroundStyle(Color.egInk)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                PointMark(x: .value("Run", run.number), y: .value("Time", run.seconds))
                    .foregroundStyle(Color.egInk)
                    .symbol(.square)
                    .symbolSize(38)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis {
            AxisMarks(values: Array(1...max(a.runs.count, b.runs.count, 1))) { value in
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text("R\(n)")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(Color.egGray)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.egHairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f", v))
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.egGray)
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private func runByRun(_ a: Driver, _ b: Driver) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                EGColumnLabel(text: "RUN-BY-RUN")
                Spacer()
                EGColumnLabel(text: "GAP")
            }
            .padding(.bottom, 6)

            ForEach(0..<max(a.runs.count, b.runs.count), id: \.self) { index in
                let runA = index < a.runs.count ? a.runs[index] : nil
                let runB = index < b.runs.count ? b.runs[index] : nil
                let gap = runA.flatMap { ra in runB.map { rb in ra.seconds - rb.seconds } }

                HStack(spacing: 8) {
                    Text("R\(index + 1)")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.egGray)
                        .frame(width: 22, alignment: .leading)
                    Text(runA?.timeString ?? "—")
                        .font(.system(size: 13, weight: (gap ?? 0) < 0 ? .heavy : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle((gap ?? 0) < 0 ? Color.egRed : Color.egInk)
                        .frame(width: 62, alignment: .leading)
                    gapBar(gap)
                    Text(runB?.timeString ?? "—")
                        .font(.system(size: 13, weight: (gap ?? 0) > 0 ? .heavy : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle((gap ?? 0) > 0 ? Color.egRed : Color.egInk)
                        .frame(width: 62, alignment: .trailing)
                    Text(gap.map { LapTime.gap($0) } ?? "—")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.egGrayDark)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) {
                    Color.egHairline.frame(height: 1)
                }
            }
        }
    }

    private func gapBar(_ gap: Double?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Color.egMeBg
                if let gap {
                    let fraction = min(abs(gap) / 2.5, 1) * 0.5
                    Color.egRed
                        .frame(width: width * fraction)
                        .offset(x: gap < 0 ? width * (0.5 - fraction) : width * 0.5)
                }
                Color.egDivider
                    .frame(width: 2)
                    .offset(x: width * 0.5 - 1)
            }
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity)
    }
}
