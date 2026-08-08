import OndKit
import OndUI
import SwiftUI

@main
struct OndApp: App {
    /// This install's anonymous id, minted on first use and read from the
    /// Keychain thereafter. Handed to every repository, so one person is one
    /// identity across the whole app — and one *store*, so a sign-in that swaps
    /// the id is not left racing a second cache. See `LiveIdentity`.
    private let identity: any UserIdentityStore = LiveIdentity.store

    /// One store for the whole app: every session ends up in the same file, and
    /// the journey's sync has one place to drain. Concrete rather than `any
    /// SessionRecording`, because the sync queue also needs its other face —
    /// the tombstones deletions wait in until the server confirms them.
    private let sessions = FileSessionStore()

    /// What the screens record through: the same file, with each kept session
    /// also credited to Health as Mindful Minutes. The journey's sync below
    /// keeps the bare store — history restored from the server is not new
    /// practice, and must never write to Health again.
    private let recorder: any SessionRecording

    /// Controlled-pause scores, kept beside the sessions and for the same
    /// reason — the journey tab reads them with no network at all.
    private let scores: any BoltScoreRecording = FileBoltScoreStore()

    /// Hands the identity above to the watch app, which never mints one of its
    /// own. Composed here because the pairing belongs to the install rather
    /// than to any screen, and because this is where the identity already is.
    private let watch: WatchLink

    /// In the environment rather than passed down, because the cue picker on the
    /// detail screen and the session that reads the setting are not adjacent.
    @State private var settings = SessionSettings()

    /// Whether this person has önd Plus. In the environment for the same
    /// reason `settings` is: the surfaces that offer a subscription — the
    /// assistant's two strips, and the paywall they open — are nowhere near
    /// here, and threading a parameter through every screen between would touch
    /// every one of them.
    @State private var plus: SubscriptionStore

    /// Which exercises' cautions have been put away. In the environment beside
    /// `settings` for the same reason: the card that writes it and the detail
    /// screen that reads it are one view apart, but the store has to outlive
    /// every push and pop between them.
    @State private var safetyNotes = SafetyNoteStore()

    /// Holds the onboarding answers and knows whether they have been given.
    @State private var profiles: ProfileStore

    /// Signing in with Apple, signing out, and staying local-only. In the
    /// environment because the rows that offer it are in Settings, two pushes
    /// below a tab root that has no use for it.
    @State private var account: AccountModel

    /// Separate from `profiles.hasCompletedOnboarding`, which is set the moment
    /// the last answer is stored — a screen that dismissed itself on that flag
    /// would vanish before the person saw the last card.
    @State private var isOnboarding: Bool

    /// One catalogue model for every tab: home's wheel and the techniques list
    /// are two views onto the same load. Built here, at the composition root,
    /// so a preview or a test can substitute the reading behind it without
    /// touching the network.
    @State private var catalogue: TechniqueListModel

    /// The basics, shared the same way — reference data loaded once.
    @State private var foundations: FoundationsModel

    /// The standing appointments, backed by local notifications. Composed here
    /// so the store outlives the Settings screen that edits it — the
    /// notifications have to stay honest whether or not it is ever opened.
    @State private var schedules = ScheduleStore(notifier: NotificationScheduler())

    /// Totals, streaks, and the boards. Local-first: everything it shows about
    /// this person is folded from the two stores above, so the tab is complete
    /// before the sync it starts has finished.
    @State private var journey: JourneyModel

    /// Watched so the watch's copy of the identity and the personal best is
    /// refreshed on every foreground, rather than only on the launch that built
    /// this scene.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let identity = identity
        let baseURL = AppConfiguration.apiBaseURL
        recorder = MindfulMinutesRecorder(wrapping: sessions, health: HealthKitHealthStore())
        let outbox = WatchHandoffOutbox(identity: identity, scores: scores)
        let watch = WatchLink(outbox: outbox)
        self.watch = watch

        let techniques = CachedTechniqueRepository(
            caching: TechniqueRepository(baseURL: baseURL, identity: identity)
        )
        _catalogue = State(wrappedValue: TechniqueListModel(techniques: techniques))
        _foundations = State(wrappedValue: FoundationsModel(topics: techniques))

        let profiles = ProfileStore(
            profiles: ProfileRepository(baseURL: baseURL, identity: identity)
        )
        _profiles = State(wrappedValue: profiles)
        _isOnboarding = State(wrappedValue: !profiles.hasCompletedOnboarding)

        let plus = SubscriptionStore(
            front: StoreKitStoreFront(),
            entitlements: EntitlementRepository(baseURL: baseURL, identity: identity)
        )
        _plus = State(wrappedValue: plus)

        let journeys = JourneyRepository(baseURL: baseURL, identity: identity)
        let sessions = sessions
        let scores = scores
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: scores,
            journeys: journeys,
            tombstones: sessions
        )
        let journey = JourneyModel(
            sessions: sessions,
            scores: scores,
            journeys: journeys,
            queue: queue
        )
        _journey = State(wrappedValue: journey)

        _account = State(
            wrappedValue: AccountModel(
                identity: identity,
                accounts: AccountRepository(baseURL: baseURL, identity: identity),
                // Everything on this device that holds something about the
                // person, for the deletion to empty. Written out here because
                // this is the only place that knows the whole of it, and a store
                // missing from this line is a "delete everything" that quietly
                // leaves that one behind.
                stores: [sessions, scores, queue, profiles, plus, LiveHealth.model, outbox]
            ) {
                // The two things that hold their own copy of the identity: the
                // watch, which was handed one and caches it, and the restore,
                // which has already walked the history of whoever this device
                // used to be. Both are told here rather than at the sign-in
                // button, so signing out and deleting fan out exactly as signing
                // in does.
                watch.push()
                await journey.syncAdoptedIdentity()
                // Last, and unconditional, because a deletion has emptied the
                // stores this model folds its numbers from — and `sync` only
                // re-reads when a *restore* changed something, which is a case a
                // freshly minted identity never has.
                await journey.refresh()
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            // The whole of the chrome is `AppChrome`'s. Reminders live behind a
            // link in Settings; the subscription has no home of its own,
            // opening from whatever was locked.
            AppChrome(
                catalogue: catalogue,
                sessions: recorder,
                journey: journey,
                profiles: profiles,
                foundations: foundations
            )
            .tint(Theme.Accent.brand)
            // The palette resolves per appearance through the asset catalogue,
            // so one override here re-themes every screen; nil follows the
            // system, which keeps the default behaviour exactly today's.
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(settings)
            .environment(account)
            .environment(plus)
            .environment(safetyNotes)
            .environment(schedules)
            .fullScreenCover(isPresented: $isOnboarding) {
                OnboardingView(
                    model: OnboardingModel(
                        store: profiles,
                        schedules: schedules,
                        catalogue: catalogue
                    )
                ) {
                    isOnboarding = false
                }
            }
            // Answers given with no signal reach the server on a later launch.
            // Cheap when there is nothing outstanding, which is every launch
            // after the first — and the same is true of the sessions recorded
            // while it was unreachable.
            // Concurrently: neither depends on the other, and the journey drain
            // should not wait out a profile request's timeout to start.
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                watch.push()
            }
            .task {
                async let profile: Void = profiles.syncIfNeeded()
                async let sessions: Void = journey.sync()
                _ = await (profile, sessions)
            }
            // Its own task because it never returns: the first thing it does is
            // read the entitlement off the device and push anything the server
            // has not acknowledged, and then it listens for renewals and refunds
            // for as long as the app is running. Folded into the task above it
            // would hold the other two open forever.
            .task { await plus.watch() }
        }
    }
}

private extension Appearance {
    /// What `preferredColorScheme` takes: an override, or nil to follow the
    /// system. Mapped here rather than in OndKit so the domain package
    /// stays free of SwiftUI, and here rather than in `OndStyle` because
    /// this scene is the only reader and the mapping touches no palette.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
