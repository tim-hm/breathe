import BreatheKit
import BreatheUI
import SwiftUI

struct TechniqueListView: View {
    @State private var model: TechniqueListModel

    /// Handed down from the composition root and passed to each session, so
    /// every session in the app writes to the one store.
    private let sessions: any SessionRecording

    init(model: TechniqueListModel, sessions: any SessionRecording) {
        _model = State(wrappedValue: model)
        self.sessions = sessions
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Breathe")
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
        }
        .task { await model.load() }
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

            Text(cycleDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.close)
    }

    /// "4 phases · 16s cycle". Reads the shape of the technique at a glance,
    /// which is what someone choosing between four of them actually needs.
    private var cycleDescription: String {
        let seconds = technique.cycleDuration.components.seconds
        return "\(technique.phases.count) phases · \(seconds)s cycle"
    }
}
