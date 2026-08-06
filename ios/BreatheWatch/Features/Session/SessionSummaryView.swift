import BreatheKit
import BreatheUI
import SwiftUI

/// What you did, said once and warmly — the phone's summary at wrist size.
///
/// The copy rule from the business plan holds here more than anywhere: celebrate
/// what happened, never grade it. A session ended early is still a session.
struct SessionSummaryView: View {
    let record: SessionRecord
    let technique: Technique
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.standard) {
                Text(record.headline)
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)

                HStack(spacing: Theme.Spacing.standard) {
                    stat(record.cyclesLabel, "\(record.cyclesCompleted)")
                    stat("time", record.duration.formatted(.time(pattern: .minuteSecond)))
                    stat(record.breathsLabel, "\(record.breathCount)")
                }

                Button("Done", action: onDone)
                    .tint(technique.goal.accent)
            }
            .padding(.vertical, Theme.Spacing.close)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
