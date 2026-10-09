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
                .egFont(13)
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
                            .egFont(19, weight: .heavy)
                        if let subtitle {
                            Text(subtitle)
                                .egFont(11)
                                .foregroundStyle(Color.egGrayDark)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .egFont(12, weight: .heavy)
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
                .egFont(11.5, weight: .semibold)
                .foregroundStyle(Color.egDarkRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Apple's user-generated-content rules want posters to agree to terms
// before their first post; the gate shows them once per device. Posting
// also needs an account, which the server enforces.
struct GuidelinesGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    var body: some View {
        if !model.acceptedGuidelines {
            GuidelinesView()
        } else if !model.signedIn {
            SignInView()
        } else if model.needsUsername {
            UsernameView()
        } else {
            content
        }
    }
}

struct GuidelinesView: View {
    @Environment(AppModel.self) private var model

    static let rules = [
        "Only post times set on closed courses, private property, or at sanctioned events. Never from public roads.",
        "Use your real name or a nickname. No offensive names, notes, or leaderboard titles.",
        "Everything you post is public and can be seen by anyone using the app.",
        "Anything posted that breaks these rules can be reported by anyone and will be removed, and whoever posted it can be banned from posting.",
    ]

    var body: some View {
        EGSheetFrame(title: "Community Leaderboards", subtitle: "Read this once before you post.") {
            Text("Leaderboards and times are posted by people using this app, not by event organizers.")
                .egFont(13)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.rules, id: \.self) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark")
                            .egFont(11, weight: .black)
                            .foregroundStyle(Color.egRed)
                            .padding(.top, 3)
                        Text(rule)
                            .egFont(12.5)
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
    @State private var unlisted: Bool
    @State private var error: String?
    @State private var saving = false

    init(editing: LBCourse? = nil) {
        self.editing = editing
        _unlisted = State(initialValue: editing?.unlisted ?? false)
        _name = State(initialValue: editing?.name ?? "")
        _distance = State(initialValue: editing?.distanceMiles.map { Self.trim($0) } ?? "")
        _description = State(initialValue: editing?.description ?? "")
    }

    var body: some View {
        EGSheetFrame(
            title: editing == nil ? "New Leaderboard" : "Edit Leaderboard",
            subtitle: editing == nil ? "Anyone can post times to it. You can edit or delete it later." : nil
        ) {
            EGFormField(label: "NAME", placeholder: "Airfield Test Day", text: $name)
            EGFormField(label: "COURSE LENGTH (MILES, OPTIONAL)", placeholder: "1.65", text: $distance, keyboard: .decimalPad)
            EGFormField(label: "DESCRIPTION (OPTIONAL)", placeholder: "Where it starts and ends, rules, anything else", text: $description, capitalization: .sentences)
            if editing == nil {
                EGFormField(label: "YOUR NAME", placeholder: "Shown as the creator", text: $creator)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    unlisted.toggle()
                } label: {
                    HStack(spacing: 8) {
                        EGCheckbox(checked: unlisted, size: 18)
                        Text("UNLISTED")
                    }
                }
                .buttonStyle(EGChipButtonStyle())
                Text("An unlisted leaderboard stays out of the list in the app. People add it with a join code you share with them.")
                    .egFont(10.5)
                    .foregroundStyle(Color.egGrayDark)
                    .fixedSize(horizontal: false, vertical: true)
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
            createdBy: creator.nilIfEmpty,
            unlisted: unlisted
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
    @State private var year = ""
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
    @State private var manual = false
    @State private var manualTime = ""
    @State private var proof: Data?
    @State private var error: String?
    @State private var saving = false

    private var showsDetails: Bool { manual || selectedLap != nil }

    var body: some View {
        EGSheetFrame(title: "Post a Time", subtitle: course.name) {
            if manual {
                ProofPhotoBox(proof: $proof)
            } else {
                importBox
            }
            ProofModeButton(manual: $manual)
            if manual {
                EGFormField(label: "TIME", placeholder: "1:17.967", text: $manualTime, keyboard: .numbersAndPunctuation)
            }
            if showsDetails {
                EGFormField(label: "DRIVER", placeholder: "Your name", text: $driver)
                HStack(spacing: 10) {
                    EGFormField(label: "YEAR", placeholder: "2007", text: $year, keyboard: .numberPad)
                        .egWidth(110)
                    EGFormField(label: "VEHICLE", placeholder: "BMW Z4M", text: $vehicle)
                }
                EGFormField(label: "HP", placeholder: "330", text: $hp, keyboard: .numberPad)
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

    private var importBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRACKADDICT LOG")
                        .egFont(11, weight: .heavy)
                        .kerning(1)
                    Text(laps.isEmpty ? "Step 1: import a CSV export. Times are posted from the log, not typed in." : selectedLap == nil ? "Step 2: tap the lap to post." : "Fill in the details below, then post.")
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
                .egFont(10.5)
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
                    .egFont(11, weight: .heavy)
                    .egWidth(76, alignment: .leading)
                Text(lap.time ?? "—")
                    .egFont(13, weight: selected ? .heavy : .regular)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.egRed : Color.egInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(lap.distanceMiles.map { String(format: "%.2f mi", $0) } ?? "")
                    .egFont(10.5)
                    .foregroundStyle(Color.egGray)
                Text(lap.topSpeedMph.map { String(format: "%.0f mph", $0) } ?? "")
                    .egFont(10.5)
                    .foregroundStyle(Color.egGray)
                    .egWidth(58, alignment: .trailing)
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
        let lap = laps.first { $0.lap == selectedLap }
        let time: String
        if manual {
            time = manualTime.trimmingCharacters(in: .whitespaces)
            guard Self.isTime(time) else {
                error = "Enter the time as minutes:seconds, like 1:17.967."
                return
            }
            guard proof != nil else {
                error = "Choose a photo that shows this time."
                return
            }
        } else {
            guard let logged = lap?.time else {
                error = laps.isEmpty ? "Import a TrackAddict CSV to post a time." : "Tap the lap you want to post."
                return
            }
            time = logged
        }
        let vehicleName = vehicle.trimmingCharacters(in: .whitespaces)
        guard !vehicleName.isEmpty else {
            error = "Enter the vehicle."
            return
        }
        let yearText = year.trimmingCharacters(in: .whitespaces)
        guard Int(yearText).map((1880...2100).contains) == true else {
            error = "Enter the car's model year."
            return
        }
        guard let horsepower = Int(hp.trimmingCharacters(in: .whitespaces)), (0...5000).contains(horsepower) else {
            error = "Enter the car's HP as a whole number."
            return
        }
        let input = LBRunInput(
            driver: driver,
            time: time,
            // Runs have no year of their own: boards carry it in the vehicle
            // name, as the sheets they were seeded from do.
            vehicle: "\(yearText) \(vehicleName)",
            hp: horsepower,
            topSpeedMph: manual ? nil : lap?.topSpeedMph.map { ($0 * 10).rounded() / 10 },
            runDate: Self.dateString(date),
            conditions: conditions.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            legacy: legacy,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            source: manual ? "photo" : "trackaddict"
        )
        saving = true
        error = nil
        do {
            model.posterName = driver
            if manual, let proof {
                try await model.submit(SubmissionInput(courseID: course.id, run: input, proof: proof.base64EncodedString()))
            } else {
                try await model.addRun(courseID: course.id, input)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    private static func isTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ Double($0).map { $0 >= 0 } ?? false }) else {
            return false
        }
        return parts.contains { Double($0) != 0 }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct JoinCourseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var error: String?
    @State private var joining = false

    var body: some View {
        EGSheetFrame(title: "Join a Leaderboard", subtitle: "Unlisted leaderboards are added with a join code.") {
            Text("Ask whoever runs the leaderboard for its code. They can find it at the top of the leaderboard.")
                .egFont(12.5)
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            EGFormField(label: "JOIN CODE", placeholder: "ABCD2345", text: $code, capitalization: .characters)
            EGErrorText(text: error)
            Button("JOIN") {
                Task { await join() }
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            .disabled(joining)
        }
    }

    private func join() async {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else {
            error = "Enter the join code."
            return
        }
        joining = true
        error = nil
        do {
            try await model.joinCourse(code: code)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        joining = false
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
            Text("Tell us what's wrong. Reports go to the app's maintainer, who can remove anything that breaks the guidelines.")
                .egFont(12.5)
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
