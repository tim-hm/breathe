import BreatheKit
import BreatheUI
import SwiftUI

struct TechniqueListView: View {
    @State private var model: TechniqueListModel

    init(model: TechniqueListModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Breathe")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            List(techniques) { TechniqueRow(technique: $0) }
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

private struct GoalBadge: View {
    let goal: TechniqueGoal

    var body: some View {
        Text(goal.title.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.close)
            .padding(.vertical, Theme.Spacing.tight)
            .background(accent.opacity(0.15), in: Capsule())
            .foregroundStyle(accent)
    }

    /// Maps a domain value onto the palette. Lives here rather than in BreatheUI
    /// so that the design package stays free of domain types.
    private var accent: Color {
        switch goal {
        case .calm: Theme.Accent.settle
        case .sleep: Theme.Accent.night
        case .energy: Theme.Accent.spark
        case .reset: Theme.Accent.restore
        }
    }
}
