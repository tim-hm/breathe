import BreatheKit
import BreatheUI
import SwiftUI

/// What you did, said once and warmly.
///
/// The copy rule from the business plan holds here more than anywhere: celebrate
/// what happened, never grade it. A session ended early is still a session — the
/// screen says so and then gets out of the way.
struct SessionSummaryView: View {
    let record: SessionRecord
    let technique: Technique
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.loose) {
            Spacer()

            VStack(spacing: Theme.Spacing.close) {
                Text(headline)
                    .font(.largeTitle.weight(.medium))
                Text(closing)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Spacing.loose) {
                stat(record.cyclesCompleted == 1 ? "cycle" : "cycles", "\(record.cyclesCompleted)")
                stat("minutes", record.duration.formatted(.time(pattern: .minuteSecond)))
                stat(record.breathCount == 1 ? "breath" : "breaths", "\(record.breathCount)")
            }

            Spacer()

            Button("Done", action: onDone)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.close)
                .background(technique.goal.accent.opacity(0.2), in: Capsule())
        }
        .padding(Theme.Spacing.loose)
    }

    private var headline: String {
        if record.completed {
            "Nicely done."
        } else if record.cyclesCompleted > 0 {
            "Every cycle counts."
        } else {
            "Any breath counts."
        }
    }

    private var closing: String {
        (record.completed ? "That's \(technique.name) done. " : "")
            + "Come back whenever you need it."
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(value)
                .font(.title.weight(.medium))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
