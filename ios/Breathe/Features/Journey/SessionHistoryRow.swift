import BreatheKit
import BreatheUI
import SwiftUI

/// One past session: what it was, how long it ran, and when.
struct SessionHistoryRow: View {
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

    /// "2 min · 8 cycles", with "ended early" only when it was — completion is
    /// the normal case and does not need announcing (celebrate consistency,
    /// never pressure).
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
