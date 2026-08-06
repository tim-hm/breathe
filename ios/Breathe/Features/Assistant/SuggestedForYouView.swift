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
        Group {
            if let guidance = model.guidance, !suggested(from: guidance).isEmpty {
                Section {
                    ForEach(suggested(from: guidance), id: \.technique.id) { item in
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
                    Text(caption(for: guidance.source))
                        .font(.footnote)
                        .foregroundStyle(Theme.Ink.secondary)
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

    /// Resolves slugs against the catalogue, dropping any that do not match.
    ///
    /// The server has already validated them, so this drops nothing in
    /// practice — but a client holding a catalogue older than the server's is a
    /// real state, and a row that navigates nowhere is worse than no row.
    private func suggested(from guidance: Guidance) -> [(technique: Technique, reason: String)] {
        guidance.recommendations.compactMap { recommendation in
            techniques
                .first { $0.slug == recommendation.techniqueSlug }
                .map { ($0, recommendation.reason) }
        }
    }
}
