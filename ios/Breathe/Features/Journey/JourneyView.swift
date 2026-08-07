import BreatheKit
import BreatheUI
import SwiftUI

/// Everything a person has done, and where it has got them.
///
/// The numbers, the streak, the history, and the pause test all come from this
/// device, so the whole screen is there instantly and stays there in airplane
/// mode. The sync runs behind it and the leaderboards are a room you step into.
///
/// The copy rule holds throughout: celebrate consistency, never pressure. A
/// streak that has lapsed has *paused*; nobody has failed anything.
struct JourneyView: View {
    let model: JourneyModel
    let profiles: ProfileStore
    /// For resolving a record's slug to its display name. A session can outlive
    /// its technique; the slug then stands in rather than hiding the row.
    let catalogue: TechniqueListModel

    /// The row awaiting the person's confirmation before it goes — deletion
    /// takes the stats with it, so it is asked about, not swiped away.
    @State private var toDelete: SessionRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    StreakCard(stats: model.stats)
                    totals
                    boltCard
                    leaderboardCard
                    history
                }
                .padding(Theme.Spacing.standard)
            }
            .paletteGround()
            .navigationTitle("Journey")
        }
        // Local read first, so the screen is complete before anything touches
        // the network; the sync then runs behind what is already drawn.
        .task {
            await model.refresh()
            await model.sync()
        }
    }

    private var totals: some View {
        HStack(spacing: Theme.Spacing.standard) {
            StatTile(value: model.stats.sessions, label: "sessions")
            StatTile(value: model.stats.minutes, label: "minutes")
            StatTile(value: model.stats.breaths, label: "breaths")
        }
    }

    /// The way into the controlled-pause test, carrying the best result so far.
    private var boltCard: some View {
        JourneyCard(
            title: "Comfortable pause",
            caption: model.personalBest == nil
                ? "A two-minute check-in on your breathing."
                : "Your best so far. Take it again whenever.",
            value: model.personalBest.map { "\($0)s" }
        ) {
            BoltTestView(model: model)
        }
    }

    private var leaderboardCard: some View {
        JourneyCard(
            title: "Leaderboards",
            caption: profiles.profile.displayName.isEmpty
                ? "Optional, and off until you pick a name."
                : "You're listed as \(profiles.profile.displayName)."
        ) {
            LeaderboardView(model: model, profiles: profiles)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            Text("Sessions")
                .font(.headline)

            if model.history.isEmpty {
                Text("Every session you breathe lands here.")
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.secondary)
            } else {
                // Lazy, because this grows for the life of the install: somebody
                // two years in has hundreds of rows, and an eager stack builds
                // every one of them to show the four on screen.
                LazyVStack(spacing: 0) {
                    ForEach(model.history) { record in
                        SessionHistoryRow(record: record, name: name(for: record))
                            // A context menu rather than a swipe: these rows
                            // live in a ScrollView, where swipe actions do not
                            // exist, and a visible affordance per row would
                            // put a delete button beside every breath taken.
                            .contextMenu {
                                Button("Delete session", systemImage: "trash", role: .destructive) {
                                    toDelete = record
                                }
                            }
                        Divider().overlay(Theme.Surface.line)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { toDelete != nil },
                set: {
                    if !$0 {
                        toDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let record = toDelete else { return }
                toDelete = nil
                Task { await model.delete(record) }
            }
        } message: {
            Text("It comes out of your totals and streak too.")
        }
    }

    private func name(for record: SessionRecord) -> String {
        guard case let .loaded(techniques) = catalogue.state,
              let technique = techniques.first(where: { $0.slug == record.techniqueSlug })
        else {
            return record.techniqueSlug
        }
        return technique.name
    }
}

private struct StreakCard: View {
    let stats: JourneyStats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(stats.streakHeadline)
                .font(.title2.weight(.semibold))

            Text(stats.streakDetail)
                .font(.callout)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.loose)
        .background(
            Theme.Accent.brand.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(value, format: .number)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.standard)
        .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
