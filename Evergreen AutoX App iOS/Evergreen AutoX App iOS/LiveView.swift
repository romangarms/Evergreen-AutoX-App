import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model

    @State private var scrollPosition: ScrollPosition

    init(initialOffset: CGFloat) {
        _scrollPosition = State(initialValue: ScrollPosition(y: initialOffset))
    }

    var body: some View {
        if model.drivers.isEmpty {
            StatusView()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    columnHeader
                    ForEach(model.drivers) { driver in
                        ResultRowView(driver: driver)
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

    private var columnHeader: some View {
        HStack(spacing: 8) {
            EGColumnLabel(text: "POS").frame(width: 34, alignment: .leading)
            EGColumnLabel(text: "NO.").frame(width: 40, alignment: .leading)
            EGColumnLabel(text: "DRIVER").frame(maxWidth: .infinity, alignment: .leading)
            EGColumnLabel(text: "BEST").frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: 30, height: 1)
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

    var body: some View {
        let pinned = model.pins.contains(driver.startNumber)
        let isMe = driver.startNumber == model.meNumber
        let nickname = model.nicknames[driver.startNumber]

        Button {
            model.open(screen: .driver(driver.position))
        } label: {
            HStack(spacing: 8) {
                Text("P\(driver.position)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(width: 34, alignment: .leading)
                Text("#\(driver.startNumber)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.egGray)
                    .frame(width: 40, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                    Text("\(driver.runs.count) runs")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.egGray)
                }
                .frame(width: 70, alignment: .trailing)
                Button {
                    model.togglePin(driver.startNumber)
                } label: {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(pinned ? Color.egRed : Color.egGrayLight)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle().inset(by: -11))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(pinned ? Color.egPinnedBg : isMe ? Color.egMeBg : Color.clear)
            .overlay(alignment: .top) {
                Color.egHairline.frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func subtitle(nickname: String?) -> String {
        var parts: [String] = []
        if nickname != nil { parts.append(driver.name) }
        if let carClass = driver.carClass { parts.append(carClass) }
        return parts.joined(separator: " · ")
    }
}
