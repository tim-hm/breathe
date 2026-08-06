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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    StreakCard(stats: model.stats)
                    totals
                    BoltCard(model: model)
                    leaderboardLink
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

    private var leaderboardLink: some View {
        NavigationLink {
            LeaderboardView(model: model, profiles: profiles)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Leaderboards")
                        .font(.headline)
                    Text(
                        profiles.profile.displayName.isEmpty
                            ? "Optional, and off until you pick a name."
                            : "You're listed as \(profiles.profile.displayName)."
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(Theme.Spacing.standard)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
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
                ForEach(model.history) { record in
                    SessionHistoryRow(record: record, name: name(for: record))
                    Divider().overlay(Theme.Surface.line)
                }
            }
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

/// The streak, said in a way nobody has to brace for.
private struct StreakCard: View {
    let stats: JourneyStats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(headline)
                .font(.title2.weight(.semibold))

            Text(detail)
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

    private var headline: String {
        switch stats.currentStreakDays {
        case 0: stats.bestStreakDays == 0 ? "Ready when you are" : "Your streak is paused"
        case 1: "One day in"
        case let days: "\(days) days in a row"
        }
    }

    /// The best streak is always available to fall back on, which is the point
    /// of keeping it: a run that has paused is still a run somebody did.
    private var detail: String {
        if stats.currentStreakDays == 0 {
            return stats.bestStreakDays == 0
                ? "Your first session starts the count."
                : "Your longest run was \(stats.bestStreakDays) days. One session picks it up again."
        }

        if stats.currentStreakDays >= stats.bestStreakDays {
            return "That's your longest run yet."
        }
        return "Your longest run is \(stats.bestStreakDays) days."
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

/// The way into the controlled-pause test, and the last result of it.
private struct BoltCard: View {
    let model: JourneyModel

    var body: some View {
        NavigationLink {
            BoltTestView(model: model)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Comfortable pause")
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                Spacer()
                if let best = model.personalBest {
                    Text("\(best)s")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Accent.attend)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(Theme.Spacing.standard)
            .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        model.personalBest == nil
            ? "A two-minute check-in on your breathing."
            : "Your best so far. Take it again whenever."
    }
}
