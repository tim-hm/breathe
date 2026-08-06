import BreatheKit
import BreatheUI
import SwiftUI

/// The way in: say what you want, start breathing.
///
/// One decision on the screen — the intent wheel — with everything else a
/// step to the side: the catalogue and the basics are pushed, the dials live
/// on the technique's own screen. The wheel wakes up on the hour's goal and
/// offers the technique this person last used towards it, which is as much
/// context as an on-device rule should claim before M6.
struct HomeView: View {
    @State private var model: TechniqueListModel

    private let foundations: FoundationsModel
    private let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings

    /// What the wheel points at. Set once the catalogue lands — before then
    /// there is no goal known to have a technique behind it.
    @State private var goal: TechniqueGoal?
    /// Recorded history, oldest first. Refreshed on appear as well as on
    /// load, because a session finished on a pushed screen has changed what
    /// to offer by the time the person pops back here.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?

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
                .paletteGround()
                .navigationTitle("Breathe")
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .techniques:
                        TechniqueListView(model: model)
                    case .basics:
                        FoundationsView(model: foundations)
                    }
                }
        }
        .task {
            await model.load()
            history = await sessions.recordedSessions()
            settleGoal()
        }
        .onAppear {
            Task { history = await sessions.recordedSessions() }
        }
        // Refreshed on dismissal rather than left to `onAppear`, which does not
        // fire again under a cover: the session that just ended is exactly the
        // one the repeat row should now offer.
        .fullScreenCover(item: $started) {
            Task { history = await sessions.recordedSessions() }
        } content: { session in
            SessionView(model: session.model)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            loaded(techniques)

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't reach the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task {
                        await model.load()
                        settleGoal()
                    }
                }
            }
        }
    }

    private func loaded(_ techniques: [Technique]) -> some View {
        VStack(spacing: Theme.Spacing.loose) {
            Spacer()

            intentWheel(over: goals(in: techniques))

            if let chosen = chosen(from: techniques) {
                chosenTechnique(chosen)
                beginButton(chosen)
            }

            Spacer()

            if let last = HomeSuggestion.lastExercise(techniques: techniques, history: history) {
                repeatRow(last)
            }

            menu
        }
        .padding(Theme.Spacing.standard)
    }

    /// The one control: "I want to" beside a wheel of outcomes, reading as
    /// one sentence. A wheel rather than a menu because spinning through five
    /// outcomes is a calmer gesture than opening a list and reading it.
    ///
    /// The label sits beside the wheel, not above it, because a wheel centres
    /// its selection in its own frame — inline, the sentence stays on one
    /// line wherever the wheel is spun to. Kept short enough to show the
    /// selection and its neighbours and no more: a taller wheel is mostly the
    /// empty half above or below whatever is chosen.
    private func intentWheel(over goals: [TechniqueGoal]) -> some View {
        HStack(spacing: Theme.Spacing.close) {
            Text("I want to")
                .font(.title3)
                .foregroundStyle(Theme.Ink.secondary)

            Picker("I want to", selection: wheelBinding(over: goals)) {
                ForEach(goals, id: \.self) { goal in
                    Text(goal.intentObject)
                        .font(.title3.weight(.semibold))
                        .tag(goal)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 190, height: 120)
        }
    }

    /// The technique the wheel's goal resolves to, as a way through to its
    /// dials, rhythm chart, and safety note. Quiet on purpose: the person who
    /// only wants to breathe never needs to read it.
    private func chosenTechnique(_ technique: Technique) -> some View {
        NavigationLink(value: technique) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(technique.name)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func beginButton(_ technique: Technique) -> some View {
        Button {
            begin(technique)
        } label: {
            Text("Begin")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.close)
                // The ground, so the label inverts with the fill: an accent is
                // dark on white and light on near-black, and a prominent button
                // that kept white text would be unreadable in one of the two.
                .foregroundStyle(Theme.Surface.ground)
        }
        .buttonStyle(.borderedProminent)
        .tint(technique.goal.accent)
    }

    /// The last exercise, as one quiet line rather than a second big button —
    /// there is only one Begin on this screen, and this is a shortcut past
    /// the wheel for someone repeating themselves. Drawn in secondary ink
    /// rather than its goal's accent for the same reason: two prominent
    /// colours on one screen make neither of them the way in.
    private func repeatRow(_ technique: Technique) -> some View {
        Button {
            begin(technique)
        } label: {
            Label("\(technique.name) again", systemImage: "arrow.clockwise")
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private var menu: some View {
        HStack(spacing: Theme.Spacing.loose) {
            NavigationLink("All techniques", value: Destination.techniques)
            NavigationLink("The basics", value: Destination.basics)
        }
        .font(.footnote)
        .tint(Theme.Accent.brand)
    }

    /// Starts `technique` as this person dialled it — the same resolution the
    /// detail screen's Begin makes, so the two cannot start different sessions.
    private func begin(_ technique: Technique) {
        let dialled = technique.dialled(with: settings.overrides(for: technique))
        started = StartedSession(
            model: SessionModel(
                technique: dialled,
                cues: SessionCues(mode: settings.cueMode),
                recorder: sessions
            )
        )
    }

    private func chosen(from techniques: [Technique]) -> Technique? {
        guard let goal else { return nil }
        return HomeSuggestion.technique(for: goal, techniques: techniques, history: history)
    }

    /// Reads the wheel's state, and never writes a goal the catalogue cannot
    /// serve — a `Picker` whose selection is absent from its options renders
    /// blank.
    private func wheelBinding(over goals: [TechniqueGoal]) -> Binding<TechniqueGoal> {
        Binding(
            get: { goal.flatMap { goals.contains($0) ? $0 : nil } ?? goals.first ?? .calm },
            set: { goal = $0 }
        )
    }

    /// Points the wheel at the hour's goal, or at whatever the catalogue has
    /// if it has nothing for that hour.
    private func settleGoal() {
        guard case let .loaded(techniques) = model.state else { return }
        let available = goals(in: techniques)
        let hour = Calendar.current.component(.hour, from: .now)
        let wanted = HomeSuggestion.goal(forHour: hour)

        goal = available.contains(wanted) ? wanted : available.first
    }

    /// The goals present in the catalogue, in the fixed calm-first order of
    /// the enum — stable across loads, so the wheel's options never reshuffle
    /// under a person who has learned where sleep sits.
    private func goals(in techniques: [Technique]) -> [TechniqueGoal] {
        TechniqueGoal.allCases.filter { goal in
            techniques.contains { $0.goal == goal }
        }
    }
}

/// The screens reachable from home that are not a technique. A value rather
/// than a pushed view so every destination on this stack is resolved in one
/// place.
private enum Destination: Hashable {
    case techniques
    case basics
}

/// Wraps the model so `fullScreenCover(item:)` has something `Identifiable` to
/// present. The identity is the presentation's, not the session's — a new tap on
/// Begin is a new session, and this is what makes that unambiguous.
private struct StartedSession: Identifiable {
    let id = UUID()
    let model: SessionModel
}
