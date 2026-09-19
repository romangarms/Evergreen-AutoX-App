import SwiftUI
import UniformTypeIdentifiers

struct EGFormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .words

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EGColumnLabel(text: label)
            TextField(placeholder, text: $text)
                .font(.system(size: 13))
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.egCard)
                .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
        }
    }
}

struct EGSheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 19, weight: .heavy))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.egGrayDark)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .heavy))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(EGChipButtonStyle())
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationBackground(Color.egBg)
        .presentationDragIndicator(.visible)
    }
}

struct EGErrorText: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.egDarkRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Apple's user-generated-content rules want posters to agree to terms
// before their first post; the gate shows them once per device.
struct GuidelinesGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    var body: some View {
        if model.acceptedGuidelines {
            content
        } else {
            GuidelinesView()
        }
    }
}

struct GuidelinesView: View {
    @Environment(AppModel.self) private var model

    static let rules = [
        "Only post times set on closed courses, private property, or at sanctioned events. Never from public roads.",
        "Use your real name or a nickname. No offensive names, notes, or leaderboard titles.",
        "Everything you post is public and can be seen by anyone using the app.",
        "Leaderboards or runs that break these rules can be reported by anyone and will be removed.",
    ]

    var body: some View {
        EGSheetFrame(title: "Community Leaderboards", subtitle: "Read this once before you post.") {
            Text("Leaderboards and times are posted by people using this app, not by Evergreen AutoX.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.rules, id: \.self) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.egRed)
                            .padding(.top, 3)
                        Text(rule)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.egCard)
            .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
            Button("I AGREE") {
                model.acceptedGuidelines = true
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
        }
    }
}

struct CourseFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let editing: LBCourse?

    @State private var name: String
    @State private var distance: String
    @State private var description: String
    @State private var creator = ""
    @State private var error: String?
    @State private var saving = false

    init(editing: LBCourse? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _distance = State(initialValue: editing?.distanceMiles.map { Self.trim($0) } ?? "")
        _description = State(initialValue: editing?.description ?? "")
    }

    var body: some View {
        EGSheetFrame(
            title: editing == nil ? "New Leaderboard" : "Edit Leaderboard",
            subtitle: editing == nil ? "Anyone can post times to it. You can edit or delete it later." : nil
        ) {
            EGFormField(label: "NAME", placeholder: "Skidpad to 4 Corners", text: $name)
            EGFormField(label: "COURSE LENGTH (MILES, OPTIONAL)", placeholder: "1.65", text: $distance, keyboard: .decimalPad)
            EGFormField(label: "DESCRIPTION (OPTIONAL)", placeholder: "Where it starts and ends, rules, anything else", text: $description, capitalization: .sentences)
            if editing == nil {
                EGFormField(label: "YOUR NAME", placeholder: "Shown as the creator", text: $creator)
            }
            EGErrorText(text: error)
            Button(editing == nil ? "CREATE LEADERBOARD" : "SAVE CHANGES") {
                Task { await save() }
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            .disabled(saving)
        }
        .onAppear {
            if creator.isEmpty { creator = model.posterName }
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func save() async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            error = "Give the leaderboard a name."
            return
        }
        var distanceMiles: Double?
        let distanceText = distance.trimmingCharacters(in: .whitespaces)
        if !distanceText.isEmpty {
            guard let value = Double(distanceText), value > 0 else {
                error = "Course length must be a number of miles."
                return
            }
            distanceMiles = value
        }
        let creator = creator.trimmingCharacters(in: .whitespaces)
        let input = LBCourseInput(
            name: name,
            distanceMiles: distanceMiles,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdBy: creator.nilIfEmpty
        )
        saving = true
        error = nil
        do {
            if let editing {
                try await model.updateCourse(id: editing.id, input)
            } else {
                if !creator.isEmpty { model.posterName = creator }
                try await model.createCourse(input)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

struct RunFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let course: LBCourse

    @State private var driver = ""
    @State private var vehicle = ""
    @State private var hp = ""
    @State private var conditions = ""
    @State private var legacy = false
    @State private var notes = ""
    @State private var date = Date()
    @State private var showImporter = false
    @State private var importing = false
    @State private var laps: [TALap] = []
    @State private var selectedLap: Int?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        EGSheetFrame(title: "Post a Time", subtitle: course.name) {
            importBox
            EGFormField(label: "DRIVER", placeholder: "Your name", text: $driver)
            HStack(spacing: 10) {
                EGFormField(label: "VEHICLE (OPTIONAL)", placeholder: "2007 BMW Z4M", text: $vehicle)
                EGFormField(label: "HP (OPTIONAL)", placeholder: "330", text: $hp, keyboard: .numberPad)
                    .frame(width: 96)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    EGColumnLabel(text: "DATE")
                    DatePicker("", selection: $date, in: ...Date.now, displayedComponents: .date)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                EGFormField(label: "CONDITIONS", placeholder: "Dry", text: $conditions)
            }
            if let legacyDistance = course.legacyDistanceMiles, let distance = course.distanceMiles {
                legacyToggle(legacyDistance: legacyDistance, distance: distance)
            }
            EGFormField(label: "NOTES (OPTIONAL)", placeholder: "Tires, traffic, anything worth knowing", text: $notes, capitalization: .sentences)
            EGErrorText(text: error)
            Button("POST TIME") {
                Task { await save() }
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            .disabled(saving)
        }
        .onAppear {
            if driver.isEmpty { driver = model.posterName }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            if case .success(let url) = result {
                Task { await importLog(url) }
            }
        }
    }

    private var importBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRACKADDICT LOG")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(1)
                    Text(laps.isEmpty ? "Import a CSV export. The time and top speed come from the lap you pick." : "Tap the lap to post.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.egGrayDark)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showImporter = true
                } label: {
                    if importing {
                        ProgressView().frame(minWidth: 60)
                    } else {
                        Text(laps.isEmpty ? "IMPORT CSV" : "REPLACE")
                    }
                }
                .buttonStyle(EGChipButtonStyle(tint: .egRed))
                .disabled(importing)
            }
            if !laps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(laps) { lap in
                        lapRow(lap)
                    }
                }
                .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
            }
        }
        .padding(12)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
    }

    private func legacyToggle(legacyDistance: Double, distance: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                legacy.toggle()
            } label: {
                HStack(spacing: 8) {
                    EGCheckbox(checked: legacy, size: 18)
                    Text(String(format: "LEGACY %.2f MI ROUTE", legacyDistance))
                }
            }
            .buttonStyle(EGChipButtonStyle())
            Text(String(format: "Check this if the run used the old %.2f mi route. Its time is scaled to the current %.2f mi so it ranks fairly.", legacyDistance, distance))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lapRow(_ lap: TALap) -> some View {
        let selected = lap.lap == selectedLap
        return Button {
            selectedLap = lap.lap
        } label: {
            HStack(spacing: 8) {
                Text(lap.lap == 0 ? "PRE-START" : "LAP \(lap.lap)")
                    .font(.system(size: 11, weight: .heavy))
                    .frame(width: 76, alignment: .leading)
                Text(lap.time ?? "—")
                    .font(.system(size: 13, weight: selected ? .heavy : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.egRed : Color.egInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(lap.distanceMiles.map { String(format: "%.2f mi", $0) } ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.egGray)
                Text(lap.topSpeedMph.map { String(format: "%.0f mph", $0) } ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.egGray)
                    .frame(width: 58, alignment: .trailing)
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.egPinnedBg : Color.clear)
            .overlay(alignment: .top) {
                if lap.id != laps.first?.id { Color.egHairline.frame(height: 1) }
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
            let parsed = try await model.parseTrackAddict(csv: data)
            laps = parsed.filter { $0.timeSeconds != nil }
            let timedRuns = laps.filter { $0.lap != 0 }
            selectedLap = timedRuns.count == 1 ? timedRuns[0].lap : nil
            if laps.isEmpty { error = "No laps with times were found in that file." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        let driver = driver.trimmingCharacters(in: .whitespaces)
        guard !driver.isEmpty else {
            error = "Enter the driver's name."
            return
        }
        guard let lap = laps.first(where: { $0.lap == selectedLap }), let time = lap.time else {
            error = laps.isEmpty ? "Import a TrackAddict CSV to post a time." : "Tap the lap you want to post."
            return
        }
        var horsepower: Int?
        if !hp.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = Int(hp.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                error = "HP must be a whole number."
                return
            }
            horsepower = value
        }
        let input = LBRunInput(
            driver: driver,
            time: time,
            vehicle: vehicle.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            hp: horsepower,
            topSpeedMph: lap.topSpeedMph.map { ($0 * 10).rounded() / 10 },
            runDate: Self.dateString(date),
            conditions: conditions.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            legacy: legacy,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            source: "trackaddict"
        )
        saving = true
        error = nil
        do {
            model.posterName = driver
            try await model.addRun(courseID: course.id, input)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: LBReportTarget
    let subject: String
    let onSent: () -> Void

    @State private var reason = ""
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        EGSheetFrame(title: "Report", subtitle: subject) {
            Text("Tell us what's wrong. Reports go to the app's maintainer, who can remove the leaderboard or run.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            EGFormField(label: "REASON", placeholder: "Public road, fake time, offensive name…", text: $reason, capitalization: .sentences)
            EGErrorText(text: error)
            Button("SEND REPORT") {
                Task { await send() }
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            .disabled(sending)
        }
    }

    private func send() async {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            error = "Say what the problem is."
            return
        }
        sending = true
        error = nil
        do {
            try await model.report(target, reason: reason)
            onSent()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
