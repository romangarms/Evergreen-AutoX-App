import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Driver?
    @State private var renameText = ""
    @State private var confirmingReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pinned this session. Tap two to compare, or open anyone's runs.")
                    .egFont(11.5)
                    .foregroundStyle(Color.egGrayDark)
                    .fixedSize(horizontal: false, vertical: true)

                if model.friends.isEmpty {
                    Text("No one pinned yet — star drivers on the Live tab.")
                        .egFont(12)
                        .foregroundStyle(Color.egGray)
                        .padding(.top, 12)
                }

                if !model.friends.isEmpty, model.me == nil {
                    Text("Pick This Is Me from a driver's ••• menu to see everyone's gap to you.")
                        .egFont(11.5)
                        .foregroundStyle(Color.egGrayDark)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(model.friends) { friend in
                    friendRow(friend)
                }

                if model.compareSelection.count == 2,
                   let a = model.driver(number: model.compareSelection[0]),
                   let b = model.driver(number: model.compareSelection[1]) {
                    Button {
                        model.open(screen: .compare(a.position, b.position))
                    } label: {
                        HStack {
                            Text("COMPARE SELECTED")
                            Spacer()
                            Image(systemName: "arrow.right")
                                .egFont(12, weight: .heavy)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EGButtonStyle(kind: .primary))
                }

                Button("RESET PINS & NICKNAMES") {
                    confirmingReset = true
                }
                .buttonStyle(EGButtonStyle())
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await model.loadSessionData() }
        .alert("Nickname", isPresented: renamingBinding, presenting: renaming) { driver in
            TextField(driver.name, text: $renameText)
            Button("Save") {
                model.setNickname(renameText, for: driver.startNumber)
            }
            Button("Cancel", role: .cancel) {}
        } message: { driver in
            Text("Shown instead of \(driver.name). Leave it empty to use their real name.")
        }
        .confirmationDialog(
            "Reset pins and nicknames?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                model.resetPersonalization()
            }
        } message: {
            Text("This clears every pinned driver, nickname and \"this is me\" choice, for every event.")
        }
    }

    private func friendRow(_ friend: Driver) -> some View {
        let selected = model.compareSelection.contains(friend.startNumber)
        let isMe = friend.startNumber == model.meNumber
        let gap = model.gapToMe(friend)
        let nickname = model.nicknames[friend.startNumber]

        return HStack(spacing: 10) {
            Button {
                model.toggleCompareSelection(friend.startNumber)
            } label: {
                EGCheckbox(checked: selected, size: 26)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)

            Button {
                model.open(screen: .driver(friend.position))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName(friend) + (isMe ? "  (me)" : ""))
                            .egFont(13, weight: .heavy)
                            .lineLimit(1)
                        Text([nickname != nil ? friend.name : nil, runsText(friend)].compactMap(\.self).joined(separator: " · "))
                            .egFont(10)
                            .foregroundStyle(Color.egGray)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("P\(friend.position)")
                            .egFont(14, weight: .heavy)
                        if let classText = classText(friend) {
                            Text(classText)
                                .egFont(10, weight: .heavy)
                                .foregroundStyle(Color.egGrayDark)
                        }
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(friend.bestString)
                            .egFont(14, weight: .heavy)
                            .monospacedDigit()
                        Text(gapText(friend, isMe: isMe, gap: gap))
                            .egFont(10)
                            .monospacedDigit()
                            .foregroundStyle(gap.map { $0 < 0 } == true ? Color.egDarkRed : Color.egGray)
                    }
                }
                .foregroundStyle(Color.egInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            friendMenu(friend, isMe: isMe)
        }
        .padding(.leading, 12)
        .padding(.vertical, 10)
        .background(selected ? Color.egPinnedBg : Color.egCard)
        .overlay(Rectangle().strokeBorder(selected ? Color.egRed : Color.egDivider, lineWidth: 2))
    }

    private func friendMenu(_ friend: Driver, isMe: Bool) -> some View {
        Menu {
            Button {
                model.meNumber = isMe ? nil : friend.startNumber
            } label: {
                Label(isMe ? "This Isn't Me" : "This Is Me", systemImage: isMe ? "person.slash" : "person.fill.checkmark")
            }
            Button {
                renameText = model.nicknames[friend.startNumber] ?? ""
                renaming = friend
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            // You are listed whether or not you starred yourself.
            if model.pins.contains(friend.startNumber) {
                Button {
                    model.togglePin(friend.startNumber)
                } label: {
                    Label("Unpin", systemImage: "star.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .egFont(15, weight: .heavy)
                .foregroundStyle(Color.egInk)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Options for \(model.displayName(friend))")
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private func classText(_ friend: Driver) -> String? {
        guard let carClass = friend.carClass else { return nil }
        guard let position = friend.positionInClass else { return carClass }
        return "P\(position) \(carClass)"
    }

    private func runsText(_ friend: Driver) -> String? {
        guard !friend.runs.isEmpty else { return nil }
        let count = friend.runs.count == 1 ? "1 run" : "\(friend.runs.count) runs"
        guard let average = friend.average, friend.runs.count > 1 else { return count }
        return count + " · avg " + LapTime.format(average)
    }

    private func gapText(_ friend: Driver, isMe: Bool, gap: Double?) -> String {
        if let gap { return LapTime.gap(gap) + " vs me" }
        if isMe { return "baseline" }
        guard model.me == nil,
              let best = friend.best,
              let fastest = model.drivers.compactMap(\.best).min()
        else { return "—" }
        return best == fastest ? "fastest" : LapTime.gap(best - fastest) + " vs P1"
    }
}
