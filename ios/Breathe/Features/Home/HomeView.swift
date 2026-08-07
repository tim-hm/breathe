import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The way in: say what you want, start breathing.
///
/// One decision on the screen — the intent wheel — and nothing competing with
/// it. Everything else lives in the tab bar's other tabs; the only extra here
/// is the technique the wheel resolves to. The wheel wakes up
/// where it was last left — the hour's goal decides only the very first
/// launch — and offers the technique this person last used towards that
/// goal. The assistant's suggestions stay in the techniques tab: this screen
/// is one decision, and a second opinion beside it would be two.
struct HomeView: View {
    /// The catalogue the composition root owns and every tab shares.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    /// Opens Settings. Non-nil only under a chrome with no Settings tab, which
    /// is what puts a gear in this screen's corner.
    var showSettings: (() -> Void)?

    @Environment(SessionSettings.self) private var settings

    /// What the wheel points at. Set once the catalogue lands — before then
    /// there is no goal known to have a technique behind it.
    @State private var goal: TechniqueGoal?
    /// Recorded history, oldest first. Re-read on every appearance, because a
    /// session finished on a pushed screen has changed what to offer by the
    /// time the person pops back here.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?

    @Environment(SubscriptionStore.self) private var plus

    @State private var isShowingPaywall = false

    var body: some View {
        NavigationStack {
            content
                .overlay(alignment: .topTrailing) {
                    if let showSettings {
                        SettingsGearButton(action: showSettings)
                    }
                }
                .paletteGround()
                // Nothing to title. The screen is one decision and the button
                // that acts on it; a bar would add a word, a hairline, and a
                // reason to look at the top of the screen instead of the middle.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
        }
        // One task for both reads, so leaving the tab cancels a history decode
        // still in flight instead of orphaning one per switch. Started together
        // rather than in sequence: neither needs the other, and the catalogue is
        // what the screen is waiting on.
        .task {
            async let recorded = sessions.recordedSessions()
            await model.loadIfNeeded()
            settleGoal()
            history = await recorded
        }
        .paywall(highlighting: .plus, isPresented: $isShowingPaywall)
        // Refreshed on dismissal rather than left to the task above, which does
        // not run again under a cover: the session that just ended is exactly
        // the one the repeat row should now offer.
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

    /// The screen's rhythm in two equal breaths of space, one either side of
    /// the wheel. Equal spacers are what centre the screen's one decision on
    /// any screen height — the same structure that used to carry a wordmark and
    /// an orb above it, with the spacers absorbing both slots rather than the
    /// layout being redrawn around their absence.
    private func loaded(_ techniques: [Technique]) -> some View {
        let chosen = chosen(from: techniques)

        return VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.standard)

            IntentWheel(goals: TechniqueGoal.present(in: techniques), goal: $goal)

            Spacer(minLength: Theme.Spacing.standard)

            // The reading order is the doing order: what you want (wheel),
            // what that resolves to (link), then Begin — which terminates the
            // screen, with nothing beneath it for the tab bar to crowd.
            if let chosen {
                VStack(spacing: Theme.Spacing.standard) {
                    chosenTechnique(chosen)
                    beginButton(chosen)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.bottom, Theme.Spacing.loose)
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
            // The row is quiet but it is still the only way through to the
            // dials, so it carries the 44pt target the type size alone would
            // not give it — and the shape makes the gap beside the words part
            // of the target rather than a miss.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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

    /// Starts `technique` as this person dialled it, or opens the paywall where
    /// a subscription owns it. Both are `HomeStart`'s to decide.
    private func begin(_ technique: Technique) {
        let start = HomeStart(sessions: sessions, settings: settings, tier: plus.tier)
        guard let model = start.session(for: technique) else {
            isShowingPaywall = true
            return
        }

        started = StartedSession(model: model)
    }

    private func chosen(from techniques: [Technique]) -> Technique? {
        guard let goal else { return nil }
        return HomeSuggestion.technique(for: goal, techniques: techniques, history: history)
    }

    /// Points the wheel where it last sat, falling back to the hour's goal on
    /// a first launch — and to whatever the catalogue has if it serves
    /// neither.
    private func settleGoal() {
        guard case let .loaded(techniques) = model.state else { return }
        let available = TechniqueGoal.present(in: techniques)
        let hour = Calendar.current.component(.hour, from: .now)
        let wanted = settings.lastGoal ?? HomeSuggestion.goal(forHour: hour)

        goal = available.contains(wanted) ? wanted : available.first
    }
}
