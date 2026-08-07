import OndKit
import OndUI
import SwiftUI

/// The BOLT-style controlled-pause test: a short, guided measurement of how
/// settled your breathing is.
///
/// The safety framing is the design, not decoration around it. This is a
/// comfortable pause and explicitly not a breath-hold contest — the app has no
/// maximal-hold board for the same reason. Every screen here says stop at the
/// *first* definite urge, and the timer is stopped by the person rather than
/// running out.
struct BoltTestView: View {
    let model: JourneyModel

    /// Which part of the test is on screen. An enum rather than a pile of
    /// booleans, because exactly one of these is true at a time and the timer
    /// only exists in one of them.
    private enum Stage: Equatable {
        case explain
        case settle
        case holding(since: Date)
        case result(seconds: Int, isPersonalBest: Bool)
    }

    @State private var stage: Stage = .explain
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.loose) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            action
        }
        .padding(Theme.Spacing.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.ground)
        .navigationTitle("Comfortable pause")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .explain:
            instructions
        case .settle:
            step(
                title: "Breathe normally",
                detail: "A few easy breaths through your nose. When you're ready, "
                    + "breathe out gently — not fully — and start the timer."
            )
        case let .holding(since):
            holding(since: since)
        case let .result(seconds, isPersonalBest):
            result(seconds: seconds, isPersonalBest: isPersonalBest)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            Text("This measures how settled your breathing is, not how long you can hold on.")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                bullet("Sit down. Never do this standing, driving, or in water.")
                bullet("Breathe normally through your nose for a few breaths.")
                bullet("Breathe out gently, then start the timer.")
                bullet(
                    "Stop at the first definite urge to breathe — not before, and nowhere near your limit."
                )
                bullet("Your next breath should be calm. If you gasp, you held too long.")
            }
            .font(.callout)
            .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.close) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Theme.Accent.attend)
            Text(text)
        }
    }

    private func step(title: String, detail: String) -> some View {
        VStack(spacing: Theme.Spacing.standard) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The running timer, redrawn on a one-second cadence.
    ///
    /// `TimelineView` rather than a `Timer` the view owns: the elapsed time is a
    /// function of the clock, so there is no state to keep in step and nothing
    /// to invalidate if the view is rebuilt mid-hold.
    private func holding(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            VStack(spacing: Theme.Spacing.standard) {
                Text("\(elapsed(from: since, to: context.date))")
                    .font(.system(size: 72, weight: .light).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.Accent.attend)

                Text("Stop at the first definite urge to breathe.")
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(elapsed(from: since, to: context.date)) seconds")
        }
    }

    private func result(seconds: Int, isPersonalBest: Bool) -> some View {
        VStack(spacing: Theme.Spacing.standard) {
            Text("\(seconds)s")
                .font(.system(size: 72, weight: .light).monospacedDigit())
                .foregroundStyle(Theme.Accent.attend)

            Text(isPersonalBest ? "Your best yet." : "Recorded.")
                .font(.title3.weight(.semibold))

            Text(
                "This moves with sleep, stress, and how you've been breathing all day. "
                    + "One reading says less than the shape of a few over a month."
            )
            .font(.callout)
            .foregroundStyle(Theme.Ink.secondary)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch stage {
        case .explain:
            button("I'm sitting down — begin") { stage = .settle }
        case .settle:
            button("Start the timer") { stage = .holding(since: .now) }
        case let .holding(since):
            button("I need to breathe") {
                let seconds = elapsed(from: since, to: .now)
                Task {
                    let isPersonalBest = await model.record(boltSeconds: seconds)
                    stage = .result(seconds: seconds, isPersonalBest: isPersonalBest)
                }
            }
        case .result:
            button("Done") { dismiss() }
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }

    /// Whole seconds, floored and never below one — a pause the person deemed
    /// long enough to end deliberately did not last zero seconds.
    private func elapsed(from start: Date, to end: Date) -> Int {
        max(1, Int(end.timeIntervalSince(start)))
    }
}
