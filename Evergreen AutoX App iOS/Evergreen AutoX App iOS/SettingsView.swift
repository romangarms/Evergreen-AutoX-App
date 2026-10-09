import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var copiedDeviceID = false
    @State private var versionTaps = 0
    @State private var blockError: String?
    @State private var adminDashboard: AdminDashboardLink?

    private static let supportURL = URL(string: "\(AppModel.defaultBaseURL)/support")!
    private static let privacyURL = URL(string: "\(AppModel.defaultBaseURL)/privacy")!

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "AutoX Live \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("ACCOUNT")
                    AccountSection()
                }

                if model.hiddenCourseCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("LEADERBOARDS")
                        Button(model.hiddenCourseCount == 1 ? "UNHIDE 1 LEADERBOARD" : "UNHIDE \(model.hiddenCourseCount) LEADERBOARDS") {
                            model.unhideAllCourses()
                        }
                        .buttonStyle(EGButtonStyle())
                    }
                }

                if !model.blocks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("BLOCKED POSTERS")
                        Text("You don't see leaderboards or times from these posters.")
                            .egFont(11)
                            .foregroundStyle(Color.egGrayDark)
                        ForEach(model.blocks) { block in
                            HStack(spacing: 8) {
                                Text(block.label ?? "Unnamed poster")
                                    .egFont(12.5)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("UNBLOCK") {
                                    Task {
                                        do {
                                            try await model.unblock(id: block.id)
                                            blockError = nil
                                        } catch {
                                            blockError = error.localizedDescription
                                        }
                                    }
                                }
                                .buttonStyle(EGChipButtonStyle())
                            }
                        }
                        EGErrorText(text: blockError)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("ABOUT")
                    Text("An independent app. Not affiliated with any event organizer or timing provider.")
                        .egFont(11)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Link("SUPPORT", destination: Self.supportURL)
                        Link("PRIVACY POLICY", destination: Self.privacyURL)
                    }
                    .buttonStyle(EGButtonStyle())
                    Text(Self.versionLabel)
                        .egFont(11)
                        .monospacedDigit()
                        .foregroundStyle(Color.egGray)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                        }
                }

                if model.devMode || versionTaps >= 7 {
                    devSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fullScreenCover(item: $adminDashboard) { link in
            AdminDashboardView(link: link)
                .ignoresSafeArea()
        }
        .task {
            await model.loadAccount()
            await model.loadBlocks()
        }
    }

    private var devSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("DEV")
            Button {
                model.devMode.toggle()
                Task { await model.loadEvents() }
            } label: {
                HStack(spacing: 8) {
                    EGCheckbox(checked: model.devMode, size: 18)
                    Text("DEV MODE")
                }
            }
            .buttonStyle(EGChipButtonStyle())
            if model.devMode {
                Text("Custom server base URL. Use your Mac's LAN IP when running on a phone; leave empty for the official server.")
                    .egFont(11)
                    .foregroundStyle(Color.egGrayDark)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("http://192.168.1.10:8321", text: $model.customBaseURLString)
                    .egFont(12)
                    .monospaced()
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .background(Color.egCard)
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
                    .onSubmit {
                        Task { await model.loadEvents() }
                    }
                Text("The device ID is what tells the server which leaderboards and runs are yours. Anyone who has it can edit them, so only paste it into the server console.")
                    .egFont(11)
                    .foregroundStyle(Color.egGrayDark)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copiedDeviceID ? "COPIED" : "COPY DEVICE ID") {
                    UIPasteboard.general.string = DeviceIdentity.token
                    copiedDeviceID = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedDeviceID = false
                    }
                }
                .buttonStyle(EGButtonStyle())
                Text("The admin dashboard opens the server's dev console on Submissions, where manual times wait for approval. It asks for the server's admin sign-in and stays signed in for 30 days.")
                    .egFont(11)
                    .foregroundStyle(Color.egGrayDark)
                    .fixedSize(horizontal: false, vertical: true)
                Button("ADMIN DASHBOARD") {
                    adminDashboard = AdminDashboardLink(baseURLString: model.baseURLString)
                }
                .buttonStyle(EGButtonStyle())
                .disabled(AdminDashboardLink(baseURLString: model.baseURLString) == nil)
            }
            Button("HIDE DEV MODE") {
                let wasOn = model.devMode
                model.devMode = false
                versionTaps = 0
                if wasOn {
                    Task { await model.loadEvents() }
                }
            }
            .buttonStyle(EGButtonStyle())
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .egFont(12, weight: .heavy)
            .kerning(1.1)
            .foregroundStyle(Color.egGray)
    }
}
