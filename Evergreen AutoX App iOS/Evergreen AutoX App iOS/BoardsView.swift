import SwiftUI

struct BoardsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewCourse = false
    @State private var showJoinCourse = false

    private var boards: [SHEvent] {
        model.events.filter { $0.source == .leaderboard }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Button("JOIN WITH CODE") {
                        showJoinCourse = true
                    }
                    .buttonStyle(EGChipButtonStyle())
                    Button {
                        showNewCourse = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .egFont(10, weight: .black)
                            Text("NEW LEADERBOARD")
                        }
                    }
                    .buttonStyle(EGChipButtonStyle(tint: .egRed))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                row(title: "Acceleration", subtitle: "0–60, 0–30 and drag strip times") {
                    model.open(screen: .acceleration)
                }

                // Boards arrive with the events, so a failed load leaves none to show.
                if model.events.isEmpty {
                    StatusView(empty: "No leaderboards yet. Tap NEW LEADERBOARD to start one for your course.")
                } else if boards.isEmpty {
                    Text("No leaderboards yet. Tap NEW LEADERBOARD to start one for your course.")
                        .egFont(12)
                        .foregroundStyle(Color.egGrayDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                ForEach(boards) { board in
                    row(title: board.name, subtitle: subtitle(board)) {
                        model.openEvent(board.id)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await model.refreshLeaderboardEvents() }
        .sheet(isPresented: $showNewCourse) {
            GuidelinesGate { CourseFormView() }
        }
        .sheet(isPresented: $showJoinCourse) {
            JoinCourseSheet()
        }
    }

    private func subtitle(_ board: SHEvent) -> String {
        let parts = [board.location?.lengthLabel.map { "\($0) course" }, board.location?.name].compactMap(\.self)
        return parts.isEmpty ? "Community leaderboard" : parts.joined(separator: " · ")
    }

    private func row(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .egFont(13.5, weight: .heavy)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .egFont(10.5)
                        .foregroundStyle(Color.egGray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .egFont(12, weight: .heavy)
                    .foregroundStyle(Color(light: 0x9B9797, dark: 0x757070))
            }
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Color.egHairline.frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
