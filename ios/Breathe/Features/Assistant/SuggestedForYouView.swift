import BreatheKit
import BreatheUI
import SwiftUI

/// What to try next, at the top of the catalogue.
///
/// A `Section`, so it belongs to the list it leads rather than floating above
/// it, and so it disappears cleanly when there is nothing to say. There is no
/// error state and no retry button: the catalogue underneath works perfectly
/// well without a suggestion, and a person who opened this tab to read about
/// nine techniques should not be handed a failure about a tenth thing they did
/// not ask for.
struct SuggestedForYouView: View {
    /// The catalogue the guidance's slugs resolve against. Passed in rather
    /// than loaded again — the list above has already loaded it, and the server
    /// guarantees every slug it sends is one of these.
    let techniques: [Technique]

    @State private var model: GuidanceModel

    /// `assistant` is defaulted so this view can be dropped into a screen
    /// without changing that screen's initialiser. See `LiveAssistant`.
    init(techniques: [Technique], assistant: any AssistantReading = LiveAssistant.reading) {
        self.techniques = techniques
        _model = State(wrappedValue: GuidanceModel(assistant: assistant))
    }

    var body: some View {
        // Resolved once per pass rather than per reference: it walks the
        // catalogue for each recommendation, and the body re-evaluates on every
        // model change.
        let suggestion = resolved

        return Group {
            if let suggestion {
                Section {
                    ForEach(suggestion.rows) { item in
                        NavigationLink(value: item.technique) {
                            row(technique: item.technique, reason: item.reason)
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Where to start")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Ink.primary)
                        .textCase(nil)
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                        Text(caption(for: suggestion.source))
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)

                        // Offered only where the free tier has actually met its
                        // edge. A rule-based answer is the one moment somebody
                        // can see the difference Plus makes, which is a better
                        // place to ask than a banner they did not come for.
                        if case .fallback = suggestion.source {
                            PlusUpsell(reason: "Want this written for you?")
                        }
                    }
                }
            }
        }
        .task { await model.loadIfNeeded() }
    }

    private func row(technique: Technique, reason: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.close) {
                Text(technique.name)
                    .font(.headline)
                GoalBadge(goal: technique.goal)
            }
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    /// Says which it is, without dressing the fallback up as something it is
    /// not. The flag exists so the app can be accurate here; copy that read the
    /// same either way would waste it.
    private func caption(for source: GuidanceSource) -> String {
        switch source {
        case .model:
            "Chosen from what you told us at the start."
        case .fallback:
            "Based on the goals you picked."
        }
    }

    /// The rows to draw, or nil where there is nothing to say — which covers
    /// loading, an unreachable server, and guidance whose every slug this build
    /// is too old to know.
    ///
    /// Slugs are resolved against the catalogue the list already holds. The
    /// server validates them before answering, so this drops nothing in
    /// practice; a client holding an older catalogue is a real state, though,
    /// and a row that navigates nowhere is worse than no row.
    private var resolved: Suggestion? {
        guard case let .loaded(guidance) = model.state else { return nil }

        let rows: [Suggestion.Row] = guidance.recommendations.compactMap { recommendation in
            guard let technique = techniques.first(where: {
                $0.slug == recommendation.techniqueSlug
            }) else {
                return nil
            }
            return Suggestion.Row(technique: technique, reason: recommendation.reason)
        }

        return rows.isEmpty ? nil : Suggestion(rows: rows, source: guidance.source)
    }
}

/// The strip's resolved contents.
///
/// A named type rather than a tuple: SwiftUI's type checker gives up on a
/// labelled-tuple property of this shape, and the rows need an identity for
/// `ForEach` anyway.
private struct Suggestion {
    struct Row: Identifiable {
        let technique: Technique
        let reason: String

        var id: String {
            technique.id
        }
    }

    let rows: [Row]
    let source: GuidanceSource
}
