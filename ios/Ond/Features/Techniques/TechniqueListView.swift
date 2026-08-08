import OndKit
import OndUI
import SwiftUI

/// The whole catalogue, grouped by what each exercise is for.
///
/// Its own root rather than part of home: someone who wants to breathe says so
/// with home's aim word, and someone who wants to read about nine exercises
/// has come here deliberately. The model arrives shared with home — two views
/// onto one load.
struct TechniqueListView: View {
    let model: TechniqueListModel
    let own: UserTechniqueModel
    let sessions: any SessionRecording

    @Environment(SubscriptionStore.self) private var plus

    /// The locked exercise somebody tapped, which is both the paywall's trigger
    /// and the reason it is being shown. `Technique` is `Identifiable`, so this
    /// is the whole of the presentation state.
    @State private var locked: Technique?

    /// Whether the composer is open on a new exercise. Editing an existing one
    /// happens from its detail screen, where the thing being edited is already
    /// on screen.
    @State private var isComposing = false

    var body: some View {
        NavigationStack {
            content
                .paletteGround()
                .navigationTitle("Exercises")
                .toolbar { composeButton }
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, own: own, sessions: sessions)
                }
                .sheet(item: $locked) { technique in
                    PaywallView(highlighting: technique.requires)
                }
                .sheet(isPresented: $isComposing) {
                    if let limits = own.limits {
                        TechniqueComposerView(model: own, limits: limits)
                    }
                }
        }
        // Home usually starts the shared load first, but this tab must not
        // depend on ever having visited it.
        .task { await model.loadIfNeeded() }
        // Separate from the catalogue's load rather than sequenced after it: the
        // two are different services, and somebody's own exercises should not
        // wait on nine curated ones.
        .task { await own.loadIfNeeded() }
    }

    /// New, or nothing.
    ///
    /// Absent rather than disabled until the limits arrive and while the ceiling
    /// is reached: a `+` that does nothing when tapped is worse than no `+`, and
    /// the ceiling is explained on the exercise somebody would have to delete
    /// rather than on the button that will not open.
    @ToolbarContentBuilder
    private var composeButton: some ToolbarContent {
        if own.hasRoomForAnother {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isComposing = true
                } label: {
                    Label("New exercise", systemImage: "plus")
                }
            }
        }
    }

    /// The exercises this person wrote, above the catalogue — somebody who has
    /// written their own came back for it.
    ///
    /// Silent while loading and while there are none: an empty section
    /// explaining a feature is an advertisement, and the New button is already
    /// the invitation. A *failure* is not silent, though. Somebody whose
    /// exercises did not load would otherwise see a screen that looks exactly
    /// like one where they never wrote any.
    @ViewBuilder
    private var ownSection: some View {
        switch own.state {
        case .loading:
            EmptyView()

        case let .loaded(list) where !list.techniques.isEmpty:
            Section {
                ForEach(list.techniques) { technique in
                    NavigationLink(value: technique) {
                        TechniqueRow(technique: technique)
                    }
                    .listRowBackground(Color.clear)
                }
            } header: {
                ownHeader
            }

        case .loaded:
            EmptyView()

        case let .failed(message):
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                Button("Try again") {
                    Task { await own.load() }
                }
                .font(.footnote)
            } header: {
                ownHeader
            }
            .listRowBackground(Color.clear)
        }
    }

    private var ownHeader: some View {
        Text("Yours")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.Ink.primary)
            .textCase(nil)
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
                Text("The server answered, but with no exercises in it.")
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

                ownSection

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

    /// A locked exercise is a row like any other that opens the paywall
    /// instead of the detail screen.
    ///
    /// Listed rather than hidden, and drawn at full strength rather than dimmed:
    /// the catalogue is what Plus sells, so somebody has to be able to read what
    /// they would be getting. Dimming reads as a punishment for not having paid;
    /// a lock beside a name and a summary reads as an invitation, which is what
    /// this is.
    ///
    /// A locked exercise never reaches `SessionModel.starting`, but that gate is
    /// the one that actually holds — this only decides which sheet opens.
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
                            .accessibilityLabel("Included with önd Plus")
                    }
                }

                // Empty for an exercise somebody wrote — a sentence explaining
                // it to its own author is nobody's idea of useful — and an
                // empty `Text` is a blank line rather than nothing.
                if !technique.summary.isEmpty {
                    Text(technique.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Ink.secondary)
                }

                Text(technique.shapeDescription)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            Spacer(minLength: 0)

            BreathRhythmMark(technique: technique)
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
