import BreatheKit
import BreatheUI
import SwiftUI

/// The one part of the journey that genuinely needs a connection.
///
/// So it says so, quietly, and never as an error: everything else on the tab is
/// already on screen, and a person with no signal has lost nothing they own.
///
/// Only people who have chosen a display name are listed. Everybody with a score
/// is counted in the ranking, which is why the entries can skip a number — the
/// person in between is here and invisible.
struct LeaderboardView: View {
    let model: JourneyModel
    let profiles: ProfileStore

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                Picker("Board", selection: $model.board) {
                    ForEach(LeaderboardBoard.allCases) { board in
                        Text(board.title).tag(board)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.board.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)

                // Offered only when there is a decade to compare within: a scope
                // the server would refuse is not a choice worth showing.
                if profiles.profile.birthYearBand != nil {
                    Picker("Scope", selection: $model.scope) {
                        ForEach(LeaderboardScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                board
                optIn
            }
            .padding(Theme.Spacing.standard)
        }
        .paletteGround()
        .navigationTitle("Leaderboards")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) { await model.loadLeaderboard() }
    }

    /// Changing either dimension is a different board, so the fetch is keyed on
    /// both rather than driven from two `onChange` handlers that could race.
    private var reloadKey: String {
        "\(model.board.rawValue)-\(model.scope.rawValue)"
    }

    @ViewBuilder
    private var board: some View {
        switch model.leaderboard {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.loose)

        case .unreachable:
            VStack(spacing: Theme.Spacing.close) {
                Text("Leaderboards need a connection")
                    .font(.headline)
                Text("Everything else here is on your phone and stays there.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.loose)

        case let .loaded(leaderboard):
            standing(leaderboard)
            entries(leaderboard)
        }
    }

    private func standing(_ leaderboard: Leaderboard) -> some View {
        let standing = leaderboard.standing

        return VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(standing.formattedRank.map { "You're \($0)" } ?? "Nothing to rank yet")
                .font(.headline)

            Text(
                standing.rank == nil
                    ? "A session or two and you'll be on here."
                    : "\(leaderboard.board.formatted(standing.value))"
                    + (standing.listed ? "" : " · only you can see this")
            )
            .font(.caption)
            .foregroundStyle(Theme.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.standard)
        .background(
            Theme.Accent.brand.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func entries(_ leaderboard: Leaderboard) -> some View {
        if leaderboard.entries.isEmpty {
            Text("Nobody has put a name to this board yet.")
                .font(.callout)
                .foregroundStyle(Theme.Ink.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(leaderboard.entries) { entry in
                    HStack {
                        Text("\(entry.rank)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.Ink.tertiary)
                            .frame(width: 32, alignment: .trailing)

                        Text(entry.displayName)
                            .font(.body)

                        Spacer()

                        Text(leaderboard.board.formatted(entry.value))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.close)
                    .accessibilityElement(children: .combine)

                    Divider().overlay(Theme.Surface.line)
                }
            }
        }
    }

    private var optIn: some View {
        JourneyCard(
            title: profiles.profile.displayName.isEmpty ? "Join in" : "Your name",
            caption: profiles.profile.displayName.isEmpty
                ? "Pick a name and others can see you here. Leave it blank and nobody can."
                : profiles.profile.displayName
        ) {
            LeaderboardNameView(profiles: profiles)
        }
    }
}
