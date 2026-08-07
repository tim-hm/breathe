import OndKit
import OndUI
import SwiftUI

/// The science behind one exercise, written for how much breathwork this person
/// has done, and streamed so it can be read as it is written.
///
/// It continues the exercise's own summary rather than sitting behind a heading
/// of its own: the same type, the same ink, directly underneath, so the screen
/// reads as one opening passage instead of two competing ones. Nothing is drawn
/// until there is something to read — no placeholder, no spinner, and no notice
/// when the explanation cannot be fetched, because everything needed to
/// practise is already on the screen above it.
///
/// It costs a model call per visit, which the disclosure this replaced was
/// there to avoid. The quota that guards it is the server's, and running out of
/// it lands on the rule-based answer rather than on an error.
struct WhyThisWorksView: View {
    @State private var model: ExplanationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `assistant` is defaulted so this view can be dropped into a screen
    /// without changing that screen's initialiser. See `LiveAssistant`.
    init(techniqueSlug: String, assistant: any AssistantReading = LiveAssistant.reading) {
        _model = State(
            wrappedValue: ExplanationModel(assistant: assistant, techniqueSlug: techniqueSlug)
        )
    }

    var body: some View {
        // A container that is always in the hierarchy even while it has nothing
        // to show, because `.task` on a view that resolves to nothing never
        // runs — and that task is what asks for the explanation.
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            if case let .reading(text, source, isComplete) = model.state {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    // Growing text should settle rather than snap. Dropped
                    // entirely under Reduce Motion rather than shortened: the
                    // reflow repeats once per chunk, dozens of times over one
                    // paragraph.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: text)

                if isComplete {
                    Text(caption(for: source))
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.tertiary)

                    // The same rule as the suggestion strip's: only where the
                    // person has just read the plainer answer, so the offer is
                    // about something they can see rather than something they
                    // are told.
                    if case .fallback = source {
                        UpgradePrompt(reason: "Want it explained for you?", offering: .coach)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { model.startIfNeeded() }
        // Once the explanation is whole, not once per chunk: a paragraph
        // announced a few words at a time would interrupt itself all the way
        // down. Observed on the model rather than on the growing `Text`, because
        // the fallback answer arrives complete in a single step and a view that
        // is built already finished sees no change to react to.
        .onChange(of: model.state) { _, state in
            if case let .reading(text, _, true) = state {
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .onDisappear { model.cancel() }
    }

    private func caption(for source: GuidanceSource) -> String {
        switch source {
        case .model: "Written for your experience level."
        case .fallback: "From the exercise's own notes."
        }
    }
}
