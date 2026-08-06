import BreatheKit
import BreatheUI
import SwiftUI

/// The whole catalogue, grouped by what each technique is for.
///
/// Pushed from home rather than shown there: someone who wants to breathe
/// says so on the wheel, and someone who wants to read about nine techniques
/// has come here deliberately. The model arrives already loaded, so this
/// screen never fetches — it is a second view onto the catalogue home holds.
struct TechniqueListView: View {
    let model: TechniqueListModel

    var body: some View {
        content
            .paletteGround()
            .navigationTitle("Techniques")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            List {
                ForEach(goals(in: techniques), id: \.self) { goal in
                    Section {
                        ForEach(techniques.filter { $0.goal == goal }) { technique in
                            NavigationLink(value: technique) {
                                TechniqueRow(technique: technique)
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(goal.intent)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.Ink.primary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't reach the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await model.load() }
                }
            }
        }
    }

    /// The goals present in the catalogue, in the fixed calm-first order of
    /// the enum — stable across loads, so sections never reshuffle under a
    /// person who has learned where sleep lives.
    private func goals(in techniques: [Technique]) -> [TechniqueGoal] {
        TechniqueGoal.allCases.filter { goal in
            techniques.contains { $0.goal == goal }
        }
    }
}

private struct TechniqueRow: View {
    let technique: Technique

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(technique.name)
                .font(.headline)

            Text(technique.summary)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)

            Text(technique.shapeDescription)
                .font(.caption)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .padding(.vertical, Theme.Spacing.close)
    }
}

private extension Technique {
    /// "8 cycles · 16s each", or "3 rounds · you end the holds". The shape of
    /// the technique at a glance, which is what someone choosing between nine of
    /// them actually needs — and the staged ones are a different proposition
    /// from the cyclic ones, so they say so.
    var shapeDescription: String {
        guard !isStaged, let stage = stages.first else {
            let unit = recommendedRounds == 1 ? "round" : "rounds"
            return hasOpenEndedStage
                ? "\(recommendedRounds) \(unit) · you end the holds"
                : "\(recommendedRounds) \(unit) · \(stages.count) stages"
        }

        let seconds = stage.cycleDuration.components.seconds
        return "\(stage.cycles) cycles · \(seconds)s each"
    }
}
