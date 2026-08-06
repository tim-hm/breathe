import BreatheKit
import BreatheUI
import SwiftUI

/// The catalogue, and the watch app's root screen.
///
/// Flat rather than sectioned by goal: a wrist list is scrolled with a crown,
/// and section headers spend the two things this screen has least of — height
/// and glanceability — on an organisation the coloured dots already carry.
struct TechniqueListView: View {
    let model: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel

    var body: some View {
        List {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)

            case let .loaded(techniques):
                ForEach(techniques) { technique in
                    NavigationLink(value: technique) {
                        row(technique)
                    }
                }

            case let .failed(message):
                // Only reachable on a first-ever launch out of range: every
                // later failure is served from `CachedTechniqueRepository`'s
                // copy of the last catalogue the server sent.
                unreachable(message)
            }

            NavigationLink("Your journey") {
                JourneyView(model: journey)
            }
            .font(.footnote)
        }
        .navigationTitle("Breathe")
        .navigationDestination(for: Technique.self) { technique in
            TechniqueDetailView(technique: technique, sessions: sessions, journey: journey)
        }
        .task { await model.loadIfNeeded() }
    }

    private func row(_ technique: Technique) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            Circle()
                .fill(technique.goal.accent)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(technique.name)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.primary)
                Text(technique.plannedDuration.formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func unreachable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't reach the catalogue", systemImage: "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task { await model.load() }
            }
        }
        .listRowBackground(Color.clear)
    }
}
