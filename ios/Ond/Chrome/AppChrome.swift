import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The app's chrome, and the only thing `OndApp` puts on screen: four
/// destinations in the system tab bar.
///
/// Four and no more. Past five the system injects a `More` tab backed by a
/// UIKit list that cannot be customised or removed, and every root here owns a
/// `NavigationStack`, which is the arrangement that bar handles worst. Settings
/// is what that leaves out, and it is left out on purpose: a tab bar is for
/// content sections and settings is not content. It is a gear in Journey's
/// toolbar, beside the screen it configures.
///
/// Coach is a tab rather than the bottom accessory it was first built as. The
/// accessory is a floating shelf in its own glass container — right for a
/// transport control that outlives the screen under it, wrong for a destination,
/// which is what a conversation you navigate to actually is. It carries both
/// tiers: the chat once Coach is held, the offer until then. Either way it is a
/// door in the same row as the others rather than a thing hovering beside them.
///
/// The bar takes the colour of the aim on Breathe, which is why `goal` is held
/// here and lent to `HomeView` rather than owned by it. The tint stops at the
/// bar — each root re-asserts the brand accent, because a screen whose links and
/// buttons changed colour with a dial on another tab would read as a bug.
struct AppChrome: View {
    let catalogue: TechniqueListModel
    let own: UserTechniqueModel
    let sessions: any SessionRecording
    let journey: JourneyModel
    let profiles: ProfileStore
    let foundations: FoundationsModel

    /// What a tapped notification asked for. Followed here rather than by any
    /// one tab, because the exercise a reminder names has nothing to do with
    /// where the person happened to leave the app.
    let router: NotificationRouter

    /// The aim Breathe is dialled to. Nil until the catalogue lands, which is
    /// the one state with no colour to take.
    @State private var goal: TechniqueGoal?

    /// The session a notification opened, waiting on Begin. Presented over the
    /// bar rather than pushed into a tab: it is a full-screen cover from every
    /// other way in too, and the tab underneath is whatever was last used.
    @State private var invited: StartedSession?

    /// The exercise a reminder named that this tier does not open, which is both
    /// the offer's trigger and the reason it is being shown.
    @State private var locked: Technique?

    @Environment(SessionSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var plus

    var body: some View {
        // Built once rather than per `Tab`: the property is a fresh struct each
        // time it is read, and the four closures below would each construct
        // their own on every pass the aim's colour invalidates.
        let roots = roots

        // Exercises and Journey carry the same symbols as the watch's root menu
        // (`OndWatch/RootMenuView.swift`), kept in step by hand — nothing
        // reconciles the two sets of literals, so retuning one retunes both.
        return TabView {
            Tab("Breathe", systemImage: "wind") {
                root(roots.homeRoot)
            }

            Tab("Exercises", systemImage: "figure.mind.and.body") {
                root(roots.exercisesRoot)
            }

            // Two bubbles rather than one: a single bubble reads as a message
            // waiting to be opened, and this row is about a conversation.
            Tab("Coach", systemImage: "bubble.left.and.text.bubble.right") {
                root(roots.coachRoot)
            }

            Tab("Journey", systemImage: "clock.arrow.circlepath") {
                root(roots.journeyRoot)
            }
        }
        .tint(goal?.accent ?? Theme.Accent.brand)
        .tabBarMinimizeBehavior(.onScrollDown)
        .background(Theme.Surface.ground.ignoresSafeArea())
        .fullScreenCover(item: $invited) { session in
            SessionView(model: session.model, entering: .waiting)
        }
        .sheet(item: $locked) { technique in
            PaywallView(highlighting: technique.requires)
        }
        // Keyed on the request rather than run once, so a tap while the app is
        // already open takes the same road as the tap that launched it.
        .task(id: router.pending) { await follow() }
    }

    /// Opens whatever a tapped notification asked for.
    ///
    /// The await is what a cold launch needs: the tap that started the app is
    /// already waiting on the router by the time this first runs, and the
    /// catalogue its slug resolves against is not. Taken unconditionally once
    /// that wait is over — a request that resolves to nothing is dropped rather
    /// than retried, because opening where the app always would is the stated
    /// answer for an exercise the catalogue no longer has.
    private func follow() async {
        guard router.pending != nil else { return }
        await catalogue.loadIfNeeded()

        guard let payload = router.take(),
              case let .loaded(techniques) = catalogue.state,
              let destination = NotificationDestination(
                  payload, in: techniques, tier: plus.tier
              )
        else { return }

        switch destination {
        case let .session(technique):
            let start = SessionStart(sessions: sessions, settings: settings, tier: plus.tier)
            if let model = start.session(for: technique) {
                invited = StartedSession(model: model)
            }

        case let .offer(technique):
            locked = technique
        }
    }

    private var roots: AppRoots {
        AppRoots(
            catalogue: catalogue,
            own: own,
            sessions: sessions,
            journey: journey,
            profiles: profiles,
            foundations: foundations,
            goal: $goal
        )
    }

    /// One root, held at the brand accent so the aim's colour reaches the tab
    /// bar and stops there.
    private func root(_ content: some View) -> some View {
        content.tint(Theme.Accent.brand)
    }
}
