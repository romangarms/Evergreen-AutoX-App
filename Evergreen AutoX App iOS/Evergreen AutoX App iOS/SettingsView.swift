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
                        emptyBox("No drivers pinned yet. Star a driver on the Live tab first. Pinned drivers show up here so you can mark one as you.")
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
                        emptyBox("No drivers pinned yet. Nicknames appear here once you star drivers on the Live tab.")
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
                        HStack(spacing: 8) {
                            EGCheckbox(checked: model.devMode, size: 18)
                            Text("DEV MODE")
                        }
                    }
                    .buttonStyle(EGChipButtonStyle())
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

    private func emptyBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.egGray)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(Color.egCard)
        .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 2))
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
                EGCheckbox(checked: isMe)
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
            .padding(.vertical, 11)
            .contentShape(Rectangle())
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
