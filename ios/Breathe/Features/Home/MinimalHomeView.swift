import BreatheKit
import BreatheUI
import SwiftUI

/// The way in, with the orb as the button.
///
/// The same decision as `HomeView` in three bands instead of four: what you want
/// (the wheel), what that resolves to (a caption directly under it), and the act
/// (the orb). There is no separate Begin — the orb is what you press, which is
/// what buys the screen back the band it used to spend on a button, and gives
/// the app's identity somewhere to live now that the wordmark has gone.
///
/// A sibling of `HomeView` rather than a mode inside it, because one of the two
/// is going to be deleted. Everything that is not layout is shared: the wheel,
/// the suggestion rules, and the one start path that carries the subscription
/// gate.
struct MinimalHomeView: View {
    /// The catalogue the composition root owns and every tab shares.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    /// Opens Settings. Non-nil only under a chrome with no Settings tab, which
    /// is what puts a gear in this screen's corner.
    var showSettings: (() -> Void)?

    @Environment(SessionSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var plus

    /// What the wheel points at. Set once the catalogue lands — before then
    /// there is no goal known to have a technique behind it.
    @State private var goal: TechniqueGoal?
    /// Recorded history, oldest first. Re-read on every appearance, because a
    /// session finished on a pushed screen has changed what to offer by the
    /// time the person pops back here.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?
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
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Technique.self) { technique in
                    TechniqueDetailView(technique: technique, sessions: sessions)
                }
        }
        .task {
            async let recorded = sessions.recordedSessions()
            await model.loadIfNeeded()
            settleGoal()
            history = await recorded
        }
        .paywall(highlighting: .plus, isPresented: $isShowingPaywall)
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

    /// Three bands with a breath of space between each, and the orb sitting
    /// where Begin used to — low enough for a thumb, far enough from the wheel
    /// that a spin never brushes it.
    private func loaded(_ techniques: [Technique]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.loose)

            VStack(spacing: Theme.Spacing.close) {
                IntentWheel(goals: TechniqueGoal.present(in: techniques), goal: $goal)

                if let chosen = chosen(from: techniques) {
                    chosenCaption(chosen)
                }
            }

            Spacer(minLength: Theme.Spacing.loose)

            if let chosen = chosen(from: techniques) {
                OrbBeginButton(technique: chosen) { begin(chosen) }
            }

            Spacer(minLength: Theme.Spacing.loose)
        }
        .padding(.horizontal, Theme.Spacing.standard)
    }

    /// The technique the wheel resolved to, and the way through to its dials,
    /// rhythm chart, and safety note. A caption rather than a row: it sits
    /// under the wheel as the answer to it, and the person who only wants to
    /// breathe never needs to read it.
    private func chosenCaption(_ technique: Technique) -> some View {
        NavigationLink(value: technique) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(technique.name)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(Theme.Ink.tertiary)
            // Quiet, but still the only way through to the dials, so it carries
            // the 44pt target the type size alone would not give it.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

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

    /// Points the wheel where it last sat, falling back to the hour's goal on a
    /// first launch — and to whatever the catalogue has if it serves neither.
    private func settleGoal() {
        guard case let .loaded(techniques) = model.state else { return }
        let available = TechniqueGoal.present(in: techniques)
        let hour = Calendar.current.component(.hour, from: .now)
        let wanted = settings.lastGoal ?? HomeSuggestion.goal(forHour: hour)

        goal = available.contains(wanted) ? wanted : available.first
    }
}
