import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The way in: an aim, the orb, and "begin" — nothing else.
///
/// The aim is one faint word on a drum that spins sideways, and tapping it fans
/// out the full set. It wakes up where it was last left, the hour's goal decides
/// only the very first launch, and the exercise it resolves to is never named
/// here: somebody who wants a particular one goes to the exercises tab, and
/// somebody who just wants to breathe should not have to read a label to do it.
/// The assistant's suggestions stay in that tab too — this screen is one
/// decision, and a second opinion beside it would be two.
struct HomeView: View {
    /// The catalogue the composition root owns and every root shares.
    let model: TechniqueListModel
    let sessions: any SessionRecording

    @Environment(SessionSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var plus

    /// The chosen aim. Set once the catalogue lands — before then there is no
    /// goal known to have an exercise behind it.
    @State private var goal: TechniqueGoal?
    /// Whether the aim word is fanned out into the full set.
    @State private var isChoosingAim = false
    /// Recorded history, oldest first. Re-read after every session, because one
    /// just finished has changed what to offer next.
    @State private var history: [SessionRecord] = []
    @State private var started: StartedSession?
    @State private var isShowingPaywall = false

    var body: some View {
        content
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

        // A healthy server with nothing seeded would otherwise render neither
        // aim nor orb — a dead screen with no way out but relaunch.
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

    /// One band, centred: the aim word above the orb, held between equal
    /// spacers so the pair sits in the middle of any screen height.
    private func loaded(_ techniques: [Technique]) -> some View {
        // Resolved out here, not inside the `GeometryReader`: none of it
        // depends on geometry, and that closure re-runs on every rotation,
        // resize, and keyboard. `locked` walks the whole history once per aim
        // it has never been used for, so leaving it in there put an unbounded
        // scan on the path of every layout pass.
        let goals = TechniqueGoal.present(in: techniques)
        let locked = lockedGoals(among: goals, in: techniques)
        let chosen = chosen(from: techniques)

        return GeometryReader { proxy in
            // Dynamic Type follows the person's text setting, not the
            // hardware, so type sized for the smallest phones sits a touch
            // small on a Pro. Grown gently with the width and capped before
            // it stops reading as the same quiet screen.
            let typeScale = min(max(proxy.size.width / 375, 1), 1.25)
            // The width inside the padding applied below, which is the drum's
            // container. Named once so the two cannot drift apart.
            let content = proxy.size.width - Theme.Spacing.standard * 2

            VStack(spacing: 0) {
                Spacer(minLength: Theme.Spacing.loose)

                if let goal {
                    VStack(spacing: Theme.Spacing.loose) {
                        AimSelector(
                            goals: goals,
                            goal: goal,
                            locked: locked,
                            typeScale: typeScale,
                            width: content,
                            isExpanded: $isChoosingAim,
                            onSelect: select
                        )

                        if let chosen {
                            OrbBeginButton(
                                technique: chosen,
                                isLocked: !chosen.isUnlocked(for: plus.tier),
                                typeScale: typeScale
                            ) {
                                begin(chosen)
                            }
                        }
                    }
                }

                Spacer(minLength: Theme.Spacing.loose)
            }
            .padding(.horizontal, Theme.Spacing.standard)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // Simultaneous, so the fan-out's own buttons and the orb still get
            // their taps — a tap anywhere while the row is out collapses it,
            // and whatever was tapped happens too. Guarded rather than
            // unconditional: the aim word's own tap opens the row, and two
            // writers to one flag in a single event leave which one lands to
            // SwiftUI's ordering. Only collapsing when there is something to
            // collapse means the two can never both fire.
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isChoosingAim {
                        isChoosingAim = false
                    }
                }
            )
            // One firm tap as the aim changes. An impact rather than
            // `.selection`, which is the lightest haptic there is. Skipped for
            // the settle on launch — that is the app restoring state, not the
            // person choosing.
            .sensoryFeedback(.impact(weight: .medium), trigger: goal) { old, _ in old != nil }
        }
    }

    /// The aims this person's tier cannot start, so the drum can mark them.
    ///
    /// Asked of `HomeSuggestion` and not of the catalogue at large, because the
    /// lock has to predict exactly one thing: whether landing here and pressing
    /// the orb opens a session or the paywall. `chosen(from:)` resolves the
    /// technique the same way, so the mark and the orb beneath it cannot
    /// disagree — an aim with a locked exercise beside a free one is not
    /// locked, and counting the catalogue's tiers instead would say it was.
    private func lockedGoals(
        among goals: [TechniqueGoal],
        in techniques: [Technique]
    ) -> Set<TechniqueGoal> {
        Set(goals.filter { goal in
            HomeSuggestion.technique(for: goal, techniques: techniques, history: history)?
                .isUnlocked(for: plus.tier) == false
        })
    }

    /// The one place a person's choice lands: the drum, the fan-out, and
    /// VoiceOver's adjust all funnel here. `settleGoal()` deliberately does
    /// not — restoring state is not choosing, and only choices are remembered.
    private func select(_ new: TechniqueGoal) {
        goal = new
        settings.lastGoal = new
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

    /// Settles the aim where it was last left, falling back to the hour's goal
    /// on a first launch — and to whatever the catalogue has if it serves
    /// neither.
    private func settleGoal() {
        guard case let .loaded(techniques) = model.state else { return }
        let available = TechniqueGoal.present(in: techniques)
        let hour = Calendar.current.component(.hour, from: .now)
        let wanted = settings.lastGoal ?? HomeSuggestion.goal(forHour: hour)

        goal = available.contains(wanted) ? wanted : available.first
    }
}
