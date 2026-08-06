import BreatheKit
import BreatheUI
import SwiftUI

struct TechniqueListView: View {
    @State private var model: TechniqueListModel

    /// Built here rather than passed in because the basics screen is reachable
    /// only from this one, and it loads on its own the first time it appears.
    private let foundations: FoundationsModel

    /// Handed down from the composition root and passed to each session, so
    /// every session in the app writes to the one store.
    private let sessions: any SessionRecording

    init(
        model: TechniqueListModel,
        foundations: FoundationsModel,
        sessions: any SessionRecording
    ) {
        _model = State(wrappedValue: model)
        self.foundations = foundations
        self.sessions = sessions
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Breathe")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("The basics", value: Destination.foundations)
                    }
                }
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
                .navigationDestination(for: Destination.self) { _ in
                    FoundationsView(model: foundations)
                }
        }
        .task { await model.load() }
    }

    /// The one screen this stack pushes that is not a technique. An enum rather
    /// than a `Bool` flag, so adding the next one is a case rather than a
    /// second presentation mechanism.
    private enum Destination: Hashable {
        case foundations
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            List(techniques) { technique in
                NavigationLink(value: technique) {
                    TechniqueRow(technique: technique)
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
}

private struct TechniqueRow: View {
    let technique: Technique

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            HStack(spacing: Theme.Spacing.close) {
                Text(technique.name)
                    .font(.headline)
                Spacer()
                GoalBadge(goal: technique.goal)
            }

            Text(technique.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(shapeDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.close)
    }

    /// "8 cycles · 16s each", or "3 rounds · you end the holds". The shape of
    /// the technique at a glance, which is what someone choosing between nine of
    /// them actually needs — and the staged ones are a different proposition
    /// from the cyclic ones, so they say so.
    private var shapeDescription: String {
        guard let stage = technique.stages.first, technique.stages.count == 1 else {
            let rounds = technique.recommendedRounds
            let unit = rounds == 1 ? "round" : "rounds"
            return technique.hasOpenEndedStage
                ? "\(rounds) \(unit) · you end the holds"
                : "\(rounds) \(unit) · \(technique.stages.count) stages"
        }

        let seconds = stage.cycleDuration.components.seconds
        return "\(stage.cycles) cycles · \(seconds)s each"
    }
}
