import BreatheKit
import BreatheUI
import SwiftUI

/// The whole catalogue, grouped by what each technique is for.
///
/// Its own tab rather than part of home: someone who wants to breathe says so
/// on the wheel, and someone who wants to read about nine techniques has come
/// here deliberately. The model arrives shared with home — two views onto one
/// load.
struct TechniqueListView: View {
    let model: TechniqueListModel
    let sessions: any SessionRecording

    /// Opens Settings. Non-nil only under a chrome with no Settings tab, which
    /// is what puts a gear in this screen's toolbar.
    var showSettings: (() -> Void)?

    /// The basics, as a row at the foot of the catalogue. Non-nil only under a
    /// chrome with no tab for them — the same screen, pushed from here rather
    /// than rooted in a tab of its own.
    var foundations: FoundationsModel?

    @Environment(SubscriptionStore.self) private var plus

    /// The locked technique somebody tapped, which is both the paywall's trigger
    /// and the reason it is being shown. `Technique` is `Identifiable`, so this
    /// is the whole of the presentation state.
    @State private var locked: Technique?

    var body: some View {
        NavigationStack {
            content
                .paletteGround()
                .navigationTitle("Techniques")
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
                .sheet(item: $locked) { technique in
                    PaywallView(highlighting: technique.requires)
                }
                .toolbar {
                    if let showSettings {
                        ToolbarItem(placement: .topBarTrailing) {
                            SettingsGearButton(action: showSettings)
                        }
                    }
                }
        }
        // Home usually starts the shared load first, but this tab must not
        // depend on ever having visited it.
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        // Same guard as home: an empty catalogue is an answer worth naming,
        // not a blank list.
        case let .loaded(techniques) where techniques.isEmpty:
            ContentUnavailableView {
                Label("The catalogue is empty", systemImage: "wind")
            } description: {
                Text("The server answered, but with no techniques in it.")
            } actions: {
                Button("Try again") {
                    Task { await model.load() }
                }
            }

        case let .loaded(techniques):
            List {
                // Leads the catalogue rather than replacing it: somebody who
                // came here to browse still browses, and somebody who wants to
                // be told what to do is told first.
                SuggestedForYouView(techniques: techniques)

                ForEach(TechniqueGoal.present(in: techniques), id: \.self) { goal in
                    Section {
                        ForEach(techniques.filter { $0.goal == goal }) { technique in
                            row(for: technique)
                        }
                    } header: {
                        Text(goal.intent)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.Ink.primary)
                            .textCase(nil)
                    }
                }

                basicsRow
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

    /// The basics at the foot of the catalogue, where a chrome with no tab for
    /// them puts them.
    ///
    /// Last rather than first: somebody scrolling nine techniques and finding
    /// none of them obvious is exactly who the questions underneath are for, and
    /// they read as a footnote to the catalogue rather than a gate in front of
    /// it.
    @ViewBuilder
    private var basicsRow: some View {
        if let foundations {
            Section {
                NavigationLink {
                    FoundationsView(model: foundations)
                } label: {
                    Label("The basics", systemImage: "book")
                        .font(.headline)
                        .padding(.vertical, Theme.Spacing.close)
                }
                .listRowBackground(Color.clear)
            } footer: {
                Text("Belly or chest, nose or mouth, eyes open or closed — the "
                    + "questions under every technique here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
    }

    /// A locked technique is a row like any other that opens the paywall
    /// instead of the detail screen.
    ///
    /// Listed rather than hidden, and drawn at full strength rather than dimmed:
    /// the catalogue is what Plus sells, so somebody has to be able to read what
    /// they would be getting. Dimming reads as a punishment for not having paid;
    /// a lock beside a name and a summary reads as an invitation, which is what
    /// this is.
    @ViewBuilder
    private func row(for technique: Technique) -> some View {
        if technique.isUnlocked(for: plus.tier) {
            NavigationLink(value: technique) {
                TechniqueRow(technique: technique)
            }
            .listRowBackground(Color.clear)
        } else {
            Button {
                locked = technique
            } label: {
                TechniqueRow(technique: technique, isLocked: true)
            }
            // Plain, so the row does not take the accent a button would and
            // start competing with the unlocked rows above it.
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
    }
}

private struct TechniqueRow: View {
    let technique: Technique
    var isLocked = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.standard) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                HStack(spacing: Theme.Spacing.close) {
                    Text(technique.name)
                        .font(.headline)

                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            // The brand accent rather than a warning colour: the
                            // lock is the app offering something, not the app
                            // telling somebody off.
                            .foregroundStyle(Theme.Accent.brand)
                            .accessibilityLabel("Included with Breathe Plus")
                    }
                }

                Text(technique.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(technique.shapeDescription)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            Spacer(minLength: 0)

            TechniqueGlyph(technique: technique)
                .frame(width: 64, height: 34)
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
