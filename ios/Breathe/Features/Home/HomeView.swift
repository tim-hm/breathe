import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The way in: say what you want, then press the orb.
///
/// Three elements and nothing else — the wheel (what you want), the orb (the
/// act), and the word under it. The wheel wakes up where it was last left, the
/// hour's goal decides only the very first launch, and the exercise it resolves
/// to is never named here: somebody who wants a particular one goes to the
/// exercises tab, and somebody who just wants to breathe should not have to read
/// a label to do it. The assistant's suggestions stay in that tab too — this
/// screen is one decision, and a second opinion beside it would be two.
struct HomeView: View {
    /// The catalogue the composition root owns and every root shares.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    /// Opens Settings, which lives behind the gear in this screen's corner.
    let showSettings: () -> Void

    @Environment(SessionSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var plus

    /// What the wheel points at. Set once the catalogue lands — before then
    /// there is no goal known to have an exercise behind it.
    @State private var goal: TechniqueGoal?
    /// Recorded history, oldest first. Re-read after every session, because one
    /// just finished has changed what to offer next.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?
    @State private var isShowingPaywall = false

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                SettingsGearButton(action: showSettings)
            }
            .paletteGround()
            // One task for both reads, so leaving the screen cancels a history
            // decode still in flight instead of orphaning one per switch. Started
            // together rather than in sequence: neither needs the other, and the
            // catalogue is what the screen is waiting on.
            .task {
                async let recorded = sessions.recordedSessions()
                await model.loadIfNeeded()
                settleGoal()
                history = await recorded
            }
            .paywall(highlighting: .plus, isPresented: $isShowingPaywall)
            // Refreshed on dismissal rather than left to the task above, which
            // does not run again under a cover: the session that just ended is
            // exactly the one the suggestion should now account for.
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

        // A healthy server with nothing seeded would otherwise render the wheel
        // with no options and no orb — a dead screen with no way out but
        // relaunch.
        case let .loaded(techniques) where techniques.isEmpty:
            ContentUnavailableView {
                Label("The catalogue is empty", systemImage: "wind")
            } description: {
                Text("The server answered, but with no exercises in it.")
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

    /// Two bands with a breath of space around and between them, so the wheel
    /// and the orb centre themselves on any screen height rather than one of
    /// them being pinned to an edge.
    private func loaded(_ techniques: [Technique]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.loose)

            IntentWheel(goals: TechniqueGoal.present(in: techniques), goal: $goal)

            Spacer(minLength: Theme.Spacing.loose)

            if let chosen = chosen(from: techniques) {
                OrbBeginButton(technique: chosen) { begin(chosen) }
            }

            Spacer(minLength: Theme.Spacing.loose)
        }
        .padding(.horizontal, Theme.Spacing.standard)
    }

    /// Starts the exercise as this person dialled it, or opens the paywall where
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
