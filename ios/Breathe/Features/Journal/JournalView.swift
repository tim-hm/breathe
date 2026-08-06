import BreatheKit
import BreatheUI
import SwiftUI

/// Every session that has run, newest first — read straight from the local
/// store that has recorded them since M1.
///
/// The deliberately plain seed of M5's journey tab: stats, streaks, and the
/// server sync grow here once identity lands, and this list becomes their
/// backdrop rather than a screen to replace.
struct JournalView: View {
    /// For resolving a record's slug to its display name. A session can
    /// outlive its technique; the slug then stands in rather than hiding the
    /// row.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    @State private var history: [SessionRecord] = []

    var body: some View {
        NavigationStack {
            content
                .paletteGround()
                .navigationTitle("Journal")
        }
        .task { history = await sessions.recordedSessions() }
        // A session just finished on another tab is the first thing this
        // screen should show on arrival.
        .onAppear {
            Task { history = await sessions.recordedSessions() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if history.isEmpty {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Every session you breathe lands here.")
            }
        } else {
            List {
                ForEach(history.reversed()) { record in
                    JournalRow(record: record, name: name(for: record))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }

    private func name(for record: SessionRecord) -> String {
        guard case let .loaded(techniques) = model.state,
              let technique = techniques.first(where: { $0.slug == record.techniqueSlug })
        else {
            return record.techniqueSlug
        }
        return technique.name
    }
}

private struct JournalRow: View {
    let record: SessionRecord
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(name)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            Spacer()

            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .combine)
    }

    /// "2 min · 8 cycles", with "ended early" only when it was — completion
    /// is the normal case and does not need announcing (celebrate
    /// consistency, never pressure).
    private var detail: String {
        let length = record.duration
            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        let cycles = record.cyclesCompleted == 1 ? "1 cycle" : "\(record.cyclesCompleted) cycles"

        var parts = [length, cycles]
        if !record.completed {
            parts.append("ended early")
        }
        return parts.joined(separator: " · ")
    }
}
