import SwiftUI
import UniformTypeIdentifiers

struct AccelerationView: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0
    @State private var showForm = false
    @Environment(\.egLargeText) private var largeText

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ranked by 0–60 time. Times are from drag strips and closed courses. Never test on public roads.")
                        .egFont(11)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("POST A TIME") {
                        showForm = true
                    }
                    .buttonStyle(EGButtonStyle(kind: .primary))

                    SubmissionsBox(courseID: nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                if let entries = model.accelerationEntries {
                    if entries.isEmpty {
                        Text("No times yet.")
                            .egFont(12)
                            .foregroundStyle(Color.egGray)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                    } else {
                        let layout = AccelRowLayout(wide: width >= LBRowLayout.wideThreshold, largeText: largeText)
                        Section {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                AccelRow(entry: entry, rank: index + 1, layout: layout) {
                                    model.screen = .accelerationEntry(entry.id)
                                }
                            }
                        } header: {
                            AccelColumnHeader(layout: layout)
                                .padding(.top, 10)
                                .background(Color.egBg)
                        }
                    }
                } else if let error = model.accelerationError {
                    VStack(spacing: 10) {
                        Text(error)
                            .egFont(12)
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
        .task { await model.loadSubmissions() }
        .sheet(isPresented: $showForm) {
            GuidelinesGate { AccelFormView() }
        }
    }
}

private struct AccelRowLayout {
    let wide: Bool
    var largeText = false

    var showsHP: Bool { wide || !largeText }

    let rank: CGFloat = 30
    let time: CGFloat = 46
    let hp: CGFloat = 42
    let strip: CGFloat = 56
    let driver: CGFloat = 60
    let weight: CGFloat = 56
    let chevron: CGFloat = 10
}

private struct AccelColumnHeader: View {
    let layout: AccelRowLayout

    var body: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "POS").egWidth(layout.rank, alignment: .leading)
            EGColumnLabel(text: "0–60").egWidth(layout.time, alignment: .trailing)
            EGColumnLabel(text: "0–30").egWidth(layout.time, alignment: .trailing)
            if layout.showsHP {
                EGColumnLabel(text: "HP").egWidth(layout.hp)
            }
            EGColumnLabel(text: layout.wide ? "VEHICLE" : "VEHICLE · DRIVER")
                .frame(maxWidth: .infinity, alignment: .leading)
            if layout.wide {
                EGColumnLabel(text: "¼ MI").egWidth(layout.strip, alignment: .trailing)
                EGColumnLabel(text: "¼ MPH").egWidth(layout.strip, alignment: .trailing)
                EGColumnLabel(text: "⅛ MI").egWidth(layout.strip, alignment: .trailing)
                EGColumnLabel(text: "⅛ MPH").egWidth(layout.strip, alignment: .trailing)
                EGColumnLabel(text: "DRIVER").egWidth(layout.driver, alignment: .leading)
                EGColumnLabel(text: "WEIGHT").egWidth(layout.weight, alignment: .trailing)
            }
            Color.clear.frame(width: layout.chevron, height: 1)
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            row
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.egInk)
        .overlay(alignment: .top) {
            Color.egHairline.frame(height: 1)
        }
    }

    private var row: some View {
        // fixedSize makes the row settle on its tallest cell's height and
        // then offer that to every cell, so the tinted one fills the row.
        HStack(spacing: 8) {
            Text("P\(rank)")
                .egFont(14, weight: .heavy)
                .foregroundStyle(rank <= 3 ? LBEntryRow.podium[rank - 1] : Color.egInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .egWidth(layout.rank, alignment: .leading)
            Text(AccelFormat.number(entry.zeroTo60))
                .egFont(14, weight: .heavy)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .egWidth(layout.time, alignment: .trailing)
            stat(entry.zeroTo30, width: layout.time)
            if layout.showsHP {
                LBTintCell(text: entry.hp.map(String.init) ?? "—", tint: LBTint.hp(entry.hp))
                    .egWidth(layout.hp)
            }
            vehicleCell
            if layout.wide {
                stat(entry.quarterMileSeconds, width: layout.strip)
                stat(entry.quarterMileMph, width: layout.strip)
                stat(entry.eighthMileSeconds, width: layout.strip)
                stat(entry.eighthMileMph, width: layout.strip)
                Text(entry.driver ?? "—")
                    .egFont(12, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .egWidth(layout.driver, alignment: .leading)
                Text(entry.weightLb.map { "\($0) lb" } ?? "—")
                    .egFont(12)
                    .monospacedDigit()
                    .foregroundStyle(Color.egGrayDark)
                    .egWidth(layout.weight, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .egFont(11, weight: .heavy)
                .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
                .frame(width: layout.chevron)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var vehicleCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.title)
                .egFont(13, weight: .heavy)
                .lineLimit(2)
            if !layout.wide, let subtitle {
                Text(subtitle)
                    .egFont(10)
                    .monospacedDigit()
                    .foregroundStyle(Color.egGray)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String? {
        let parts = [
            entry.driver,
            entry.quarterMileSeconds.map { "¼ mi \(AccelFormat.number($0))s" },
            entry.eighthMileSeconds.map { "⅛ mi \(AccelFormat.number($0))s" },
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func stat(_ value: Double?, width: CGFloat) -> some View {
        Text(AccelFormat.number(value))
            .egFont(12)
            .monospacedDigit()
            .foregroundStyle(Color.egGrayDark)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }
}

private enum AccelFormat {
    static func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "—"
    }
}

struct AccelerationEntryView: View {
    @Environment(AppModel.self) private var model
    let entryID: Int

    @State private var reporting = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var runToDelete: Int?
    @State private var notice: String?
    @State private var actionError: String?

    var body: some View {
        if let entries = model.accelerationEntries,
           let index = entries.firstIndex(where: { $0.id == entryID }) {
            detail(entries[index], rank: index + 1)
        } else if model.accelerationEntries == nil, model.accelerationError == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("This entry is no longer on the board.")
                .egFont(12)
                .foregroundStyle(Color.egGrayDark)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ entry: AccelEntry, rank: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .egFont(24, weight: .heavy)
                            .lineLimit(2)
                        Text("P\(rank) by 0–60 time")
                            .egFont(12)
                            .foregroundStyle(Color.egGrayDark)
                        if let driver = entry.driver {
                            EGOutlineTag(text: driver.uppercased())
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions(entry)
                }

                EGStatsGrid(rows: [
                    [
                        ("0–60", seconds(entry.zeroTo60), .egRed),
                        ("0–30", seconds(entry.zeroTo30), .egInk),
                        ("HP", entry.hp.map(String.init) ?? "—", .egInk),
                    ],
                    [
                        ("¼ MILE", seconds(entry.quarterMileSeconds), .egInk),
                        ("¼ MILE MPH", AccelFormat.number(entry.quarterMileMph), .egInk),
                        ("WEIGHT", entry.weightLb.map { "\($0) lb" } ?? "—", .egInk),
                    ],
                    [
                        ("⅛ MILE", seconds(entry.eighthMileSeconds), .egInk),
                        ("⅛ MILE MPH", AccelFormat.number(entry.eighthMileMph), .egInk),
                        ("LB / HP", poundsPerHP(entry), .egInk),
                    ],
                ])

                if let notes = entry.notes {
                    Text(notes)
                        .egFont(12)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let runs = entry.otherRuns, !runs.isEmpty {
                    AccelOtherRuns(runs: runs) { runToDelete = $0 }
                }

                if let notice {
                    Text(notice)
                        .egFont(11, weight: .semibold)
                        .foregroundStyle(Color.egRed)
                }
                EGErrorText(text: actionError)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $reporting) {
            ReportSheet(target: .acceleration(entry.id), subject: "\(entry.title) on the Acceleration board") {
                notice = "Report sent. Thanks."
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive) {
                Task {
                    do {
                        try await model.deleteAcceleration(id: entry.id)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this run?",
            isPresented: Binding(get: { runToDelete != nil }, set: { if !$0 { runToDelete = nil } }),
            titleVisibility: .visible,
            presenting: runToDelete
        ) { id in
            Button("Delete Run", role: .destructive) {
                Task {
                    do {
                        try await model.deleteOtherAccelerationRun(id: id)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
        .confirmationDialog("Block whoever posted this entry?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block Poster", role: .destructive) {
                Task {
                    do {
                        try await model.blockAccelerationPoster(entryID: entry.id)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(LBBlockCopy.message)
        }
    }

    private func actions(_ entry: AccelEntry) -> some View {
        Menu {
            if entry.isOwner == true {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Entry", systemImage: "trash")
                }
            }
            Button {
                reporting = true
            } label: {
                Label("Report Entry", systemImage: "flag")
            }
            if entry.canBlockPoster {
                Button(role: .destructive) {
                    confirmBlock = true
                } label: {
                    Label("Block Poster", systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .egFont(14, weight: .heavy)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(EGChipButtonStyle())
    }

    private func seconds(_ value: Double?) -> String {
        value.map { "\(AccelFormat.number($0))s" } ?? "—"
    }

    private func poundsPerHP(_ entry: AccelEntry) -> String {
        guard let weight = entry.weightLb, let hp = entry.hp, hp > 0 else { return "—" }
        return String(format: "%.1f", Double(weight) / Double(hp))
    }
}

private struct AccelOtherRuns: View {
    let runs: [AccelEntry]
    let onDelete: (Int) -> Void

    private let time: CGFloat = 52
    private let trash: CGFloat = 32

    private var deletable: Bool { runs.contains { $0.isOwner == true } }

    var body: some View {
        Section {
            rows
        } header: {
            columnLabels
        }
    }

    private var columnLabels: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "OTHER RUNS").frame(maxWidth: .infinity, alignment: .leading)
            EGColumnLabel(text: "0–60").egWidth(time, alignment: .trailing)
            EGColumnLabel(text: "0–30").egWidth(time, alignment: .trailing)
            EGColumnLabel(text: "¼ MI").egWidth(time, alignment: .trailing)
            if deletable {
                Color.clear.frame(width: trash, height: 1)
            }
        }
        .padding(.vertical, 6)
        .background(Color.egBg.padding(.horizontal, -16))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                HStack(spacing: 8) {
                    Text(run.postedOn ?? "—")
                        .egFont(12)
                        .monospacedDigit()
                        .foregroundStyle(Color.egGrayDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AccelFormat.number(run.zeroTo60))
                        .egFont(13, weight: .heavy)
                        .monospacedDigit()
                        .egWidth(time, alignment: .trailing)
                    stat(run.zeroTo30)
                    stat(run.quarterMileSeconds)
                    if deletable {
                        Button {
                            onDelete(run.id)
                        } label: {
                            Image(systemName: "trash")
                                .egFont(12, weight: .semibold)
                                .frame(width: trash, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.egGrayDark)
                        .opacity(run.isOwner == true ? 1 : 0)
                        .disabled(run.isOwner != true)
                        .accessibilityLabel("Delete run")
                    }
                }
                .frame(minHeight: 36)
                .overlay(alignment: .top) {
                    Color.egHairline.frame(height: 1)
                }
            }
        }
    }

    private func stat(_ value: Double?) -> some View {
        Text(AccelFormat.number(value))
            .egFont(12)
            .monospacedDigit()
            .foregroundStyle(Color.egGrayDark)
            .egWidth(time, alignment: .trailing)
    }
}

struct AccelFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var driver = ""
    @State private var year = ""
    @State private var vehicle = ""
    @State private var hp = ""
    @State private var weight = ""
    @State private var notes = ""
    @State private var showImporter = false
    @State private var importing = false
    @State private var imported = false
    @State private var pulls: [TALap] = []
    @State private var selectedLap: Int?
    @State private var manual = false
    @State private var manualTimes = Array(repeating: "", count: 6)
    @State private var proof: Data?
    @State private var error: String?
    @State private var saving = false

    private var showsDetails: Bool { manual || selectedLap != nil }

    var body: some View {
        EGSheetFrame(title: "Post a Time", subtitle: "Acceleration") {
            if manual {
                ProofPhotoBox(proof: $proof)
            } else {
                importBox
            }
            ProofModeButton(manual: $manual)
            if manual {
                manualTimeFields
            }
            if showsDetails {
                EGFormField(label: "DRIVER", placeholder: "Your name", text: $driver)
                HStack(spacing: 10) {
                    EGFormField(label: "YEAR", placeholder: "2007", text: $year, keyboard: .numberPad)
                        .egWidth(110)
                    EGFormField(label: "VEHICLE", placeholder: "BMW Z4M", text: $vehicle)
                }
                HStack(spacing: 10) {
                    EGFormField(label: "HP", placeholder: "330", text: $hp, keyboard: .numberPad)
                    EGFormField(label: "WEIGHT LB (OPTIONAL)", placeholder: "3200", text: $weight, keyboard: .numberPad)
                }
                EGFormField(label: "NOTES (OPTIONAL)", placeholder: "Tires, surface, anything worth knowing", text: $notes, capitalization: .sentences)
            }
            EGErrorText(text: error)
            if showsDetails {
                Button(manual ? "SUBMIT FOR REVIEW" : "POST TIME") {
                    Task { await save() }
                }
                .buttonStyle(EGButtonStyle(kind: .primary))
                .disabled(saving)
                if manual { ProofReviewNote() }
            }
        }
        .onAppear {
            if driver.isEmpty { driver = model.posterName }
        }
        .onChange(of: manual) { error = nil }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            if case .success(let url) = result {
                Task { await importLog(url) }
            }
        }
    }

    // In the order of TAAcceleration's fields, which is how save() reads them.
    private static let manualTimeLabels = [
        ("0–30 (S)", "2.1"), ("0–60 (S)", "5.2"),
        ("¼ MILE (S)", "13.6"), ("¼ MILE (MPH)", "104"),
        ("⅛ MILE (S)", "8.8"), ("⅛ MILE (MPH)", "82"),
    ]

    private var manualTimeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([0, 2, 4], id: \.self) { first in
                HStack(spacing: 10) {
                    ForEach([first, first + 1], id: \.self) { index in
                        EGFormField(
                            label: Self.manualTimeLabels[index].0,
                            placeholder: Self.manualTimeLabels[index].1,
                            text: $manualTimes[index],
                            keyboard: .decimalPad
                        )
                    }
                }
            }
            Text("Fill in the times the photo shows. At least one is needed.")
                .egFont(10.5)
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func manualAcceleration() -> TAAcceleration? {
        var values: [Double?] = []
        for (index, text) in manualTimes.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if trimmed.isEmpty {
                values.append(nil)
            } else if let value = Double(trimmed), value > 0, value <= (index % 2 == 1 && index > 1 ? 400 : 600) {
                values.append(value)
            } else {
                error = "\(Self.manualTimeLabels[index].0.capitalized) is not a valid number."
                return nil
            }
        }
        guard [values[0], values[1], values[2], values[4]].contains(where: { $0 != nil }) else {
            error = "Enter at least one time."
            return nil
        }
        guard proof != nil else {
            error = "Choose a photo that shows these times."
            return nil
        }
        return TAAcceleration(
            zeroTo30: values[0], zeroTo60: values[1],
            quarterMileSeconds: values[2], quarterMileMph: values[3],
            eighthMileSeconds: values[4], eighthMileMph: values[5]
        )
    }

    private var importBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRACKADDICT LOG")
                        .egFont(11, weight: .heavy)
                        .kerning(1)
                    Text(pulls.isEmpty ? "Step 1: import the CSV export of a drag run. Times are posted from the log, not typed in." : selectedLap == nil ? "Step 2: tap the run to post." : "Fill in the car below, then post.")
                        .egFont(10.5)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showImporter = true
                } label: {
                    if importing {
                        ProgressView().frame(minWidth: 60)
                    } else {
                        Text(imported ? "REPLACE" : "IMPORT CSV")
                    }
                }
                .buttonStyle(EGChipButtonStyle(tint: .egRed))
                .disabled(importing)
            }
            if !pulls.isEmpty {
                VStack(spacing: 0) {
                    ForEach(pulls) { pull in
                        pullRow(pull)
                    }
                }
                .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
            }
        }
        .padding(12)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
    }

    private func pullRow(_ pull: TALap) -> some View {
        let selected = pull.lap == selectedLap
        let times = pull.acceleration
        let summary = [
            times?.zeroTo60.map { "0–60 \(AccelFormat.number($0))s" },
            times?.zeroTo30.map { "0–30 \(AccelFormat.number($0))s" },
            times?.quarterMileSeconds.map { "¼ mi \(AccelFormat.number($0))s" },
            times?.eighthMileSeconds.map { "⅛ mi \(AccelFormat.number($0))s" },
        ].compactMap(\.self).joined(separator: " · ")
        return Button {
            selectedLap = pull.lap
        } label: {
            HStack(spacing: 8) {
                Text("RUN \(pull.lap)")
                    .egFont(11, weight: .heavy)
                    .egWidth(52, alignment: .leading)
                Text(summary)
                    .egFont(12, weight: selected ? .heavy : .regular)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.egRed : Color.egInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.egPinnedBg : Color.clear)
            .overlay(alignment: .top) {
                if pull.id != pulls.first?.id { Color.egHairline.frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func importLog(_ url: URL) async {
        importing = true
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            importing = false
        }
        do {
            let data = try Data(contentsOf: url)
            pulls = try await model.parseTrackAddict(csv: data).filter { $0.acceleration != nil }
            imported = true
            selectedLap = pulls.count == 1 ? pulls[0].lap : nil
            if pulls.isEmpty { error = "No run from a standing start was found in that file." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        let driver = driver.trimmingCharacters(in: .whitespaces)
        let vehicle = vehicle.trimmingCharacters(in: .whitespaces)
        guard !driver.isEmpty else {
            error = "Enter the driver's name."
            return
        }
        guard !vehicle.isEmpty else {
            error = "Enter the vehicle."
            return
        }
        let times: TAAcceleration
        if manual {
            guard let typed = manualAcceleration() else { return }
            times = typed
        } else {
            guard let logged = pulls.first(where: { $0.lap == selectedLap })?.acceleration else {
                error = pulls.isEmpty ? "Import a TrackAddict CSV to post a time." : "Tap the run you want to post."
                return
            }
            times = logged
        }
        var numbers: [Int?] = []
        for (label, text, range) in [("Year", year, 1880...2100), ("HP", hp, 0...5000), ("Weight", weight, 1...200_000)] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, label == "Weight" {
                numbers.append(nil)
            } else if trimmed.isEmpty {
                error = "Enter the car's \(label == "HP" ? label : label.lowercased())."
                return
            } else if let value = Int(trimmed), range.contains(value) {
                numbers.append(value)
            } else {
                error = "\(label) is not a valid number."
                return
            }
        }
        let input = AccelEntryInput(
            vehicle: vehicle,
            year: numbers[0],
            driver: driver,
            hp: numbers[1],
            weightLb: numbers[2],
            zeroTo30: times.zeroTo30,
            zeroTo60: times.zeroTo60,
            quarterMileSeconds: times.quarterMileSeconds,
            quarterMileMph: times.quarterMileMph,
            eighthMileSeconds: times.eighthMileSeconds,
            eighthMileMph: times.eighthMileMph,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            source: manual ? "photo" : "trackaddict"
        )
        saving = true
        error = nil
        do {
            model.posterName = driver
            if manual, let proof {
                try await model.submit(SubmissionInput(acceleration: input, proof: proof.base64EncodedString()))
            } else {
                try await model.addAcceleration(input)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
