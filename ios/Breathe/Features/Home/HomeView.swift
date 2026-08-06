import BreatheKit
import BreatheUI
import SwiftUI

/// The way in: say what you want, start breathing.
///
/// One decision on the screen — the intent wheel — under the brand's own
/// breathing orb. Everything else lives in the tab bar's other tabs; the only
/// extra here is the technique the wheel resolves to. The wheel wakes up
/// where it was last left — the hour's goal decides only the very first
/// launch — and offers the technique this person last used towards that
/// goal, which is as much context as an on-device rule should claim
/// before M6.
struct HomeView: View {
    /// The catalogue the composition root owns and every tab shares.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings

    /// What the wheel points at. Set once the catalogue lands — before then
    /// there is no goal known to have a technique behind it.
    @State private var goal: TechniqueGoal?
    /// Recorded history, oldest first. Re-read on every appearance, because a
    /// session finished on a pushed screen has changed what to offer by the
    /// time the person pops back here.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?

    var body: some View {
        NavigationStack {
            content
                .paletteGround()
                // The wordmark below is this screen's title; the bar would
                // duplicate it and cage the orb under a hairline.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
        }
        .task {
            await model.loadIfNeeded()
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

        // A healthy server with nothing seeded would otherwise render the
        // orb, the wheel with no options, and no Begin — a dead screen with
        // no way out but relaunch.
        case let .loaded(techniques) where techniques.isEmpty:
            ContentUnavailableView {
                Label("The catalogue is empty", systemImage: "wind")
            } description: {
                Text("The server answered, but with no techniques in it.")
            } actions: {
                retryButton
            }

        case let .loaded(techniques):
            loaded(techniques)

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't reach the catalogue", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("Try again") {
            Task {
                await model.load()
                settleGoal()
            }
        }
    }

    private func loaded(_ techniques: [Technique]) -> some View {
        let chosen = chosen(from: techniques)

        return VStack(spacing: 0) {
            wordmark
                .padding(.top, Theme.Spacing.standard)

            Spacer()

            VStack(spacing: Theme.Spacing.loose) {
                AmbientOrb(accent: chosen?.goal.accent ?? Theme.Accent.brand)

                intentWheel(over: goals(in: techniques))

                if let chosen {
                    VStack(spacing: Theme.Spacing.standard) {
                        chosenTechnique(chosen)
                        beginButton(chosen)
                    }
                }
            }

            Spacer()
        }
        .padding(Theme.Spacing.standard)
    }

    /// The site's wordmark, in the site's voice: serif, letterspaced, quiet.
    private var wordmark: some View {
        Text("BREATHE")
            .font(.system(size: 15, weight: .medium, design: .serif))
            .tracking(6)
            .foregroundStyle(Theme.Ink.secondary)
            .accessibilityAddTraits(.isHeader)
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
    /// blank. Every spin is remembered, which is the whole of the app's
    /// repeat functionality: come back and the wheel is where you left it.
    private func wheelBinding(over goals: [TechniqueGoal]) -> Binding<TechniqueGoal> {
        Binding(
            get: {
                if let goal, goals.contains(goal) {
                    goal
                } else {
                    goals.first ?? .calm
                }
            },
            set: {
                goal = $0
                settings.lastGoal = $0
            }
        )
    }

    /// Points the wheel where it last sat, falling back to the hour's goal on
    /// a first launch — and to whatever the catalogue has if it serves
    /// neither.
    private func settleGoal() {
        guard case let .loaded(techniques) = model.state else { return }
        let available = goals(in: techniques)
        let hour = Calendar.current.component(.hour, from: .now)
        let wanted = settings.lastGoal ?? HomeSuggestion.goal(forHour: hour)

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

/// Wraps the model so `fullScreenCover(item:)` has something `Identifiable` to
/// present. The identity is the presentation's, not the session's — a new tap on
/// Begin is a new session, and this is what makes that unambiguous.
private struct StartedSession: Identifiable {
    let id = UUID()
    let model: SessionModel
}
