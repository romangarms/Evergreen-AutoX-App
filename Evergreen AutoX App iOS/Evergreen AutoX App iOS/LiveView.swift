import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model

    @State private var scrollPosition: ScrollPosition
    @State private var isPickingMe = false

    init(initialOffset: CGFloat) {
        _scrollPosition = State(initialValue: ScrollPosition(y: initialOffset))
    }

    var body: some View {
        if model.drivers.isEmpty {
            StatusView()
        } else {
            VStack(spacing: 0) {
                if isPickingMe || model.showsMePrompt {
                    mePrompt
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ResultsColumnHeader()
                        ForEach(model.drivers) { driver in
                            ResultRowView(driver: driver, onTap: isPickingMe ? { pickMe(driver) } : nil)
                        }
                    }
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    if offset >= 0 {
                        model.liveScrollOffset = offset
                    }
                }
                .refreshable { await model.loadSessionData() }
            }
        }
    }

    private func pickMe(_ driver: Driver) {
        model.meNumber = driver.startNumber
        isPickingMe = false
    }

    // Sits above the scroll view so the instruction stays visible while
    // scrolling a long field to find yourself.
    private var mePrompt: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isPickingMe ? "Tap yourself in the list" : "Which driver is you?")
                    .font(.system(size: 12.5, weight: .heavy))
                    .foregroundStyle(Color.egInk)
                Text(isPickingMe ? "Change it later from the ⋯ menu on any driver." : "Get a ME tag and gaps to your friends.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.egGrayDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPickingMe {
                Button("CANCEL") {
                    isPickingMe = false
                }
                .buttonStyle(EGChipButtonStyle())
            } else {
                Button("FIND ME") {
                    isPickingMe = true
                }
                .buttonStyle(EGChipButtonStyle(tint: .egRed))
                Button {
                    model.dismissMePrompt()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.egGray)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, isPickingMe ? 16 : 8)
        .padding(.vertical, 8)
        .background(isPickingMe ? Color.egPinnedBg : Color.egMeBg)
        .overlay(alignment: .bottom) {
            Color.egDivider.frame(height: 1)
        }
    }
}

struct ResultsColumnHeader: View {
    var showsNumber = true
    var showsPin = true

    var body: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "POS").frame(width: 34, alignment: .leading)
            if showsNumber {
                EGColumnLabel(text: "NO.").frame(width: 40, alignment: .leading)
            }
            EGColumnLabel(text: "DRIVER").frame(maxWidth: .infinity, alignment: .leading)
            EGColumnLabel(text: "BEST").frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: showsPin ? 36 : 12, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            if model.isLoading {
                ProgressView()
                Text("Loading timing data…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.egGrayDark)
            } else if let error = model.errorMessage {
                EGTag(text: "OFFLINE", background: .egDarkRed)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.egGrayDark)
                    .multilineTextAlignment(.center)
                Text("Check the server URL in Setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.egGray)
                Button("RETRY") {
                    Task { await model.loadEvents() }
                }
                .buttonStyle(EGButtonStyle(kind: .primary))
            } else {
                Text("No results in this session yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.egGrayDark)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultRowView: View {
    @Environment(AppModel.self) private var model
    let driver: Driver
    var showsNumber = true
    var showsPin = true
    var onTap: (() -> Void)?

    var body: some View {
        let pinned = model.pins.contains(driver.startNumber)
        let isMe = driver.startNumber == model.meNumber
        let nickname = model.nicknames[driver.startNumber]

        HStack(spacing: 0) {
            Button {
                if let onTap {
                    onTap()
                } else {
                    model.open(screen: .driver(driver.position))
                }
            } label: {
                HStack(spacing: 8) {
                    Text("P\(driver.position)")
                        .font(.system(size: 14, weight: .heavy))
                        .frame(width: 34, alignment: .leading)
                    if showsNumber {
                        Text("#\(driver.startNumber)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Color.egGray)
                            .frame(width: 40, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(model.displayName(driver))
                                .font(.system(size: 13, weight: .heavy))
                                .lineLimit(1)
                            if isMe {
                                EGTag(text: "ME", background: .egInk, foreground: .egBg, size: 8.5)
                            }
                        }
                        Text(subtitle(nickname: nickname))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.egGray)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(driver.bestString)
                            .font(.system(size: 14, weight: .heavy))
                            .monospacedDigit()
                        Text(driver.runs.count == 1 ? "1 run" : "\(driver.runs.count) runs")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.egGray)
                    }
                    .frame(width: 70, alignment: .trailing)
                    if !showsPin {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
                            .frame(width: 12)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, showsPin ? 8 : 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsPin {
                Button {
                    model.togglePin(driver.startNumber)
                } label: {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(pinned ? Color.egRed : Color.egGray)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
        }
        .foregroundStyle(Color.egInk)
        .background(pinned ? Color.egPinnedBg : isMe ? Color.egMeBg : Color.clear)
        .overlay(alignment: .top) {
            Color.egHairline.frame(height: 1)
        }
    }

    private func subtitle(nickname: String?) -> String {
        var parts: [String] = []
        if nickname != nil { parts.append(driver.name) }
        if let carClass = driver.carClass { parts.append(carClass) }
        return parts.joined(separator: " · ")
    }
}
