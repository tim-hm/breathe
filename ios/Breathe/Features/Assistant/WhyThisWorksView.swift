import BreatheKit
import BreatheUI
import SwiftUI

/// The science behind one technique, written for how much breathwork this
/// person has done, and streamed so it can be read as it is written.
///
/// Behind a disclosure and closed by default, for two reasons: the detail
/// screen's job is to get somebody breathing, and an explanation nobody opened
/// should not spend a model call.
struct WhyThisWorksView: View {
    @State private var model: ExplanationModel
    @State private var isOpen = false

    /// `assistant` is defaulted so this view can be dropped into a screen
    /// without changing that screen's initialiser. See `LiveAssistant`.
    init(techniqueSlug: String, assistant: any AssistantReading = LiveAssistant.reading) {
        _model = State(
            wrappedValue: ExplanationModel(assistant: assistant, techniqueSlug: techniqueSlug)
        )
    }

    var body: some View {
        DisclosureGroup("Why this works", isExpanded: $isOpen) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.close)
        }
        // The call is made on opening, not on appearing — which is the whole
        // reason this is a disclosure rather than a section.
        .onChange(of: isOpen) { _, opened in
            if opened {
                model.startIfNeeded()
            }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .waiting:
            // A single line of placeholder rather than a spinner: the text is
            // about to start arriving, and a spinner that lives for one second
            // reads as a stall.
            Text("Reading…")
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)

        case let .reading(text, source, isComplete):
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.primary)
                    // Growing text should settle rather than snap, and the
                    // running total changes on every chunk.
                    .animation(.easeOut(duration: 0.15), value: text)

                if isComplete {
                    Text(caption(for: source))
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)

                    // The same rule as the suggestion strip's: only where the
                    // person has just read the plainer answer, so the offer is
                    // about something they can see rather than something they
                    // are told.
                    if case .fallback = source {
                        PlusUpsell(reason: "Want it explained for you?", offering: .coach)
                    }
                }
            }

        case .unavailable:
            // Calm, and honest about the fact that nothing was lost: the
            // technique's own summary and safety note are already on this
            // screen, above.
            Text("Not available just now. Everything you need to practise is above.")
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func caption(for source: GuidanceSource) -> String {
        switch source {
        case .model: "Written for your experience level."
        case .fallback: "From the technique's own notes."
        }
    }
}
