import SwiftUI

struct AccelerationView: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    EGBackButton(label: "EVENTS") {
                        model.goBack()
                        model.tab = .events
                    }

                    Text("Acceleration")
                        .font(.system(size: 19, weight: .heavy))

                    Text("Ranked by 0–60 time")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.egGrayDark)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                if let entries = model.accelerationEntries {
                    if entries.isEmpty {
                        Text("No times yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGray)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                    } else {
                        let layout = AccelRowLayout(wide: width >= LBRowLayout.wideThreshold)
                        AccelColumnHeader(layout: layout)
                            .padding(.top, 10)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            AccelRow(entry: entry, rank: index + 1, layout: layout)
                        }
                    }
                } else if let error = model.accelerationError {
                    VStack(spacing: 10) {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGrayDark)
                            .multilineTextAlignment(.center)
                        Button("RETRY") {
                            model.open(screen: .acceleration)
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
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct AccelRowLayout {
    let wide: Bool

    let rank: CGFloat = 30
    let time: CGFloat = 46
    let hp: CGFloat = 42
    let strip: CGFloat = 56
    let driver: CGFloat = 60
    let weight: CGFloat = 56
}

private struct AccelColumnHeader: View {
    let layout: AccelRowLayout

    var body: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "POS").frame(width: layout.rank, alignment: .leading)
            EGColumnLabel(text: "0–60").frame(width: layout.time, alignment: .trailing)
            EGColumnLabel(text: "0–30").frame(width: layout.time, alignment: .trailing)
            EGColumnLabel(text: "HP").frame(width: layout.hp)
            EGColumnLabel(text: layout.wide ? "VEHICLE" : "VEHICLE · DRIVER")
                .frame(maxWidth: .infinity, alignment: .leading)
            if layout.wide {
                EGColumnLabel(text: "¼ MI").frame(width: layout.strip, alignment: .trailing)
                EGColumnLabel(text: "¼ MPH").frame(width: layout.strip, alignment: .trailing)
                EGColumnLabel(text: "⅛ MI").frame(width: layout.strip, alignment: .trailing)
                EGColumnLabel(text: "⅛ MPH").frame(width: layout.strip, alignment: .trailing)
                EGColumnLabel(text: "DRIVER").frame(width: layout.driver, alignment: .leading)
                EGColumnLabel(text: "WEIGHT").frame(width: layout.weight, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct AccelRow: View {
    let entry: AccelEntry
    let rank: Int
    let layout: AccelRowLayout

    var body: some View {
        // fixedSize makes the row settle on its tallest cell's height and
        // then offer that to every cell, so the tinted one fills the row.
        HStack(spacing: 8) {
            Text("P\(rank)")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(rank <= 3 ? LBEntryRow.podium[rank - 1] : Color.egInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: layout.rank, alignment: .leading)
            Text(Self.number(entry.zeroTo60))
                .font(.system(size: 14, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: layout.time, alignment: .trailing)
            stat(entry.zeroTo30, width: layout.time)
            LBTintCell(text: entry.hp.map(String.init) ?? "—", tint: LBTint.hp(entry.hp))
                .frame(width: layout.hp)
            vehicleCell
            if layout.wide {
                stat(entry.quarterMileSeconds, width: layout.strip)
                stat(entry.quarterMileMph, width: layout.strip)
                stat(entry.eighthMileSeconds, width: layout.strip)
                stat(entry.eighthMileMph, width: layout.strip)
                Text(entry.driver ?? "—")
                    .font(.system(size: 12, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: layout.driver, alignment: .leading)
                Text(entry.weightLb.map { "\($0) lb" } ?? "—")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.egGrayDark)
                    .frame(width: layout.weight, alignment: .trailing)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .foregroundStyle(Color.egInk)
        .overlay(alignment: .top) {
            Color.egHairline.frame(height: 1)
        }
    }

    private var vehicleCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text([entry.year.map(String.init), entry.vehicle].compactMap(\.self).joined(separator: " "))
                .font(.system(size: 13, weight: .heavy))
                .lineLimit(2)
            if !layout.wide {
                ForEach(details, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Color.egGray)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: [String] {
        let who = [entry.driver, entry.weightLb.map { "\($0) lb" }].compactMap(\.self)
        let strip = [
            Self.strip("¼ mi", seconds: entry.quarterMileSeconds, mph: entry.quarterMileMph),
            Self.strip("⅛ mi", seconds: entry.eighthMileSeconds, mph: entry.eighthMileMph),
        ].compactMap(\.self)
        return [who, strip].filter { !$0.isEmpty }.map { $0.joined(separator: " · ") }
    }

    private func stat(_ value: Double?, width: CGFloat) -> some View {
        Text(Self.number(value))
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Color.egGrayDark)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }

    private static func strip(_ label: String, seconds: Double?, mph: Double?) -> String? {
        guard let seconds else { return nil }
        let speed = mph.map { " @ \(number($0)) mph" } ?? ""
        return "\(label) \(number(seconds))s\(speed)"
    }

    private static func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "—"
    }
}
