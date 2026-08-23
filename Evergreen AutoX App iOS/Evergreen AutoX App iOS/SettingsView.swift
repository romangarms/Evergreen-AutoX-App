import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("THIS IS ME")
                    Text("Drives the ME tag and the gaps on the Friends tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.egGrayDark)
                    if meCandidates.isEmpty {
                        Text("Pin drivers on the Live tab first, then pick yourself here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGray)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(meCandidates.enumerated()), id: \.element.id) { index, driver in
                                meRow(driver, isFirst: index == 0)
                            }
                        }
                        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("NICKNAMES")
                    if model.friends.isEmpty {
                        Text("Nicknames appear here once you pin drivers.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.egGray)
                    }
                    ForEach(model.friends) { friend in
                        HStack(spacing: 8) {
                            Text(friend.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.egGrayDark)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            TextField("Nickname", text: nicknameBinding(friend.startNumber))
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(Color.egCard)
                                .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("SERVER")
                    Text("Official server")
                        .font(.system(size: 12))
                        .foregroundStyle(model.devMode ? Color.egGray : Color.egInk)
                    if model.devMode {
                        Text("Custom server base URL. Use your Mac's LAN IP when running on a phone; leave empty for the default server.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.egGrayDark)
                        TextField("http://192.168.1.10:8321", text: $model.customBaseURLString)
                            .font(.system(size: 12))
                            .monospaced()
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(Color.egCard)
                            .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
                    }
                    Button("RECONNECT") {
                        Task { await model.loadEvents() }
                    }
                    .buttonStyle(EGButtonStyle(kind: .primary))
                }

                Button("RESET PINS & NICKNAMES") {
                    model.resetPersonalization()
                }
                .buttonStyle(EGButtonStyle())

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("DEV")
                    Button {
                        model.devMode.toggle()
                        Task { await model.loadEvents() }
                    } label: {
                        HStack(spacing: 10) {
                            Rectangle()
                                .strokeBorder(model.devMode ? Color.egRed : Color.egDivider, lineWidth: 2)
                                .background(model.devMode ? Color.egRed : Color.clear)
                                .frame(width: 14, height: 14)
                            Text("DEV MODE")
                                .font(.system(size: 11, weight: .heavy))
                                .kerning(1.1)
                        }
                        .foregroundStyle(Color.egInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meCandidates: [Driver] {
        model.drivers.filter { model.pins.contains($0.startNumber) || $0.startNumber == model.meNumber }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .kerning(1.1)
            .foregroundStyle(Color.egGray)
    }

    private func meRow(_ driver: Driver, isFirst: Bool) -> some View {
        let isMe = driver.startNumber == model.meNumber
        return Button {
            model.meNumber = isMe ? nil : driver.startNumber
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .strokeBorder(isMe ? Color.egRed : Color.egDivider, lineWidth: 2)
                    .background(isMe ? Color.egRed : Color.clear)
                    .frame(width: 14, height: 14)
                Text(model.displayName(driver))
                    .font(.system(size: 12.5, weight: isMe ? .heavy : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("#\(driver.startNumber)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.egGray)
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                if !isFirst { Color.egHairline.frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    private func nicknameBinding(_ number: String) -> Binding<String> {
        Binding(
            get: { model.nicknames[number] ?? "" },
            set: { model.setNickname($0, for: number) }
        )
    }
}
