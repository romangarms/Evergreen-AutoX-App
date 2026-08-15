import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pinned this session. Tap two to compare, or open anyone's runs.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.egGrayDark)

                if model.friends.isEmpty {
                    Text("No one pinned yet — star drivers on the Live tab.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.egGray)
                        .padding(.top, 12)
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
                                .font(.system(size: 12, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EGButtonStyle(kind: .primary))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await model.loadSessionData() }
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
                ZStack {
                    Rectangle()
                        .strokeBorder(selected ? Color.egRed : Color.egDivider, lineWidth: 2)
                        .background(selected ? Color.egRed : Color.clear)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color.egOnRed)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle().inset(by: -15))
            }
            .buttonStyle(.plain)

            Button {
                model.open(screen: .driver(friend.position))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName(friend) + (isMe ? "  (me)" : ""))
                            .font(.system(size: 13, weight: .heavy))
                            .lineLimit(1)
                        Text([nickname != nil ? friend.name : nil, "P\(friend.position)", friend.carClass].compactMap(\.self).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.egGray)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(friend.bestString)
                            .font(.system(size: 14, weight: .heavy))
                            .monospacedDigit()
                        Text(gapText(isMe: isMe, gap: gap))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(gap.map { $0 < 0 } == true ? Color.egDarkRed : Color.egGray)
                    }
                }
                .foregroundStyle(Color.egInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Color.egPinnedBg : Color.egCard)
        .overlay(Rectangle().strokeBorder(selected ? Color.egRed : Color.egDivider, lineWidth: 2))
    }

    private func gapText(isMe: Bool, gap: Double?) -> String {
        if isMe { return "baseline" }
        guard let gap else { return model.me == nil ? "set me in Setup" : "—" }
        return LapTime.gap(gap) + " vs me"
    }
}
