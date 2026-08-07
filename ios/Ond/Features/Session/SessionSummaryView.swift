import OndKit
import OndStyle
import OndUI
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
                Text(record.headline)
                    .font(.largeTitle.weight(.medium))
                // Only a completed session gets a second line — the headline
                // already says everything an ended one needs to hear.
                if record.completed {
                    Text("That's \(technique.name) done.")
                        .font(.body)
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: Theme.Spacing.loose) {
                stat(record.cyclesLabel, "\(record.cyclesCompleted)")
                stat("minutes", record.duration.formatted(.time(pattern: .minuteSecond)))
                stat(record.breathsLabel, "\(record.breathCount)")
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.standard)
            // Translucent, so the accent wash the session was drawn in still
            // shows through the one thing left on the screen.
            .background(Theme.Surface.raised.opacity(0.6), in: card)
            .overlay(card.stroke(Theme.Surface.line))

            Spacer()

            Button("Done", action: onDone)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.close)
                .background(technique.goal.accent.opacity(0.2), in: Capsule())
        }
        .padding(Theme.Spacing.loose)
        .foregroundStyle(Theme.Ink.primary)
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(value)
                .font(.title.weight(.medium))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
