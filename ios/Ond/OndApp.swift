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
    /// reason — the journey tab reads them with no network at all. Concrete for
    /// the reason the sessions are: a deletion has to be able to empty it.
    private let scores = FileBoltScoreStore()

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

    /// Whether the safety terms have been agreed to, and the record of it. Held
    /// here rather than passed into onboarding alone because it is also what
    /// decides whether somebody who onboarded before that step existed is asked
    /// on this launch.
    @State private var consent = SafetyConsentStore()

    /// Holds the onboarding answers and knows whether they have been given.
    @State private var profiles: ProfileStore

    /// Signing in with Apple, signing out, and staying local-only. In the
    /// environment because the rows that offer it are in Settings, two pushes
    /// below a tab root that has no use for it.
    @State private var account: AccountModel

    /// What this install still owes before anybody breathes, decided once at
    /// launch and cleared when it is met.
    ///
    /// One piece of state for both covers rather than a flag each. They are
    /// mutually exclusive — a new install meets the safety terms as a step of
    /// onboarding, so it is never asked twice — and an enum is what makes that
    /// true rather than merely intended. Separate from
    /// `profiles.hasCompletedOnboarding`, which is set the moment the last
    /// answer is stored: a screen that dismissed itself on that flag would
    /// vanish before the person saw the last card.
    @State private var firstRun: FirstRunGate?

    /// One catalogue model for every tab: home's wheel and the techniques list
    /// are two views onto the same load. Built here, at the composition root,
    /// so a preview or a test can substitute the reading behind it without
    /// touching the network.
    @State private var catalogue: TechniqueListModel

    /// The basics, shared the same way — reference data loaded once.
    @State private var foundations: FoundationsModel

    /// The exercises this person wrote for themselves. Its own model rather
    /// than part of the catalogue's: they come from a different service, they
    /// need the identity, and they are written as well as read.
    @State private var own: UserTechniqueModel

    /// The standing appointments, backed by local notifications. Composed in
    /// `init` rather than inline so the deletion below can reach it — the
    /// pending requests are iOS's rather than this app's, and nothing else can
    /// take them back. It outlives the Settings screen that edits it either way,
    /// because the notifications have to stay honest whether or not it is ever
    /// opened.
    @State private var schedules: ScheduleStore

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

        let schedules = ScheduleStore(notifier: NotificationScheduler())
        _schedules = State(wrappedValue: schedules)

        let techniques = CachedTechniqueRepository(
            caching: TechniqueRepository(baseURL: baseURL, identity: identity)
        )
        _catalogue = State(wrappedValue: TechniqueListModel(techniques: techniques))
        _foundations = State(wrappedValue: FoundationsModel(topics: techniques))

        let own = UserTechniqueModel(
            store: UserTechniqueRepository(baseURL: baseURL, identity: identity)
        )
        _own = State(wrappedValue: own)

        let profiles = ProfileStore(
            profiles: ProfileRepository(baseURL: baseURL, identity: identity)
        )
        _profiles = State(wrappedValue: profiles)

        let consent = SafetyConsentStore()
        _consent = State(wrappedValue: consent)
        _firstRun = State(wrappedValue: .pending(profiles: profiles, consent: consent))

        let plus = SubscriptionStore(
            front: StoreKitStoreFront(),
            entitlements: EntitlementRepository(baseURL: baseURL, identity: identity)
        )
        _plus = State(wrappedValue: plus)

        let (journey, queue) = Self.journey(
            baseURL: baseURL,
            identity: identity,
            sessions: sessions,
            scores: scores
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
                stores: [
                    sessions, scores, queue, profiles, consent, schedules, plus, LiveHealth.model,
                    outbox,
                ],
                onIdentityChange: Self.identityChange(
                    telling: watch, and: journey, reloading: own
                )
            )
        )
    }

    /// The journey tab's model and the queue that drains into it.
    ///
    /// Built together and returned together because they are one thing built
    /// twice over: the queue is the model's sync, and it is also one of the
    /// stores a deletion has to empty — so the composition root needs both, and
    /// nothing else needs either.
    private static func journey(
        baseURL: URL,
        identity: any UserIdentityStore,
        sessions: FileSessionStore,
        scores: FileBoltScoreStore
    ) -> (JourneyModel, SessionSyncQueue) {
        let journeys = JourneyRepository(baseURL: baseURL, identity: identity)
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: scores,
            journeys: journeys,
            tombstones: sessions
        )

        return (
            JourneyModel(sessions: sessions, scores: scores, journeys: journeys, queue: queue),
            queue
        )
    }

    /// What every path that changes the identity has to do once it has.
    ///
    /// A function rather than a closure written inline because it is the same
    /// three steps for signing in, signing out and deleting — and because the
    /// reason each of them is there outgrew the argument list it was sitting in.
    private static func identityChange(
        telling watch: WatchLink,
        and journey: JourneyModel,
        reloading own: UserTechniqueModel
    ) -> @MainActor () async -> Void {
        {
            // The two things that hold their own copy of the identity: the
            // watch, which was handed one and caches it, and the restore, which
            // has already walked the history of whoever this device used to be.
            // Both are told here rather than at the sign-in button, so signing
            // out and deleting fan out exactly as signing in does.
            watch.push()
            await journey.syncAdoptedIdentity()
            // Last, and unconditional, because a deletion has emptied the stores
            // this model folds its numbers from — and `sync` re-reads only when
            // a *restore* changed something, which is a case a freshly minted
            // identity never has.
            await journey.refresh()
            // Server-side and scoped to the id, so a changed identity is a
            // different list — and unlike the journey's stores, there is nothing
            // local to reconcile, only a fetch to redo.
            await own.load()
        }
    }

    var body: some Scene {
        WindowGroup {
            // The whole of the chrome is `AppChrome`'s. Reminders live behind a
            // link in Settings; the subscription has no home of its own,
            // opening from whatever was locked.
            AppChrome(
                catalogue: catalogue,
                own: own,
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
            .environment(schedules)
            .fullScreenCover(item: $firstRun) { gate in
                switch gate {
                case .onboarding:
                    OnboardingView(
                        model: OnboardingModel(
                            store: profiles,
                            schedules: schedules,
                            catalogue: catalogue,
                            consent: consent
                        )
                    ) {
                        firstRun = nil
                    }

                case .safety:
                    SafetyConsentView(store: consent) {
                        firstRun = nil
                    }
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

/// What the app puts in front of everything else on a launch, before anything
/// can be breathed.
///
/// Two states rather than two booleans, because they must never both be true:
/// onboarding already carries the safety terms as its last step, so the standalone
/// version is only ever for an install that finished the flow before that step
/// existed.
private enum FirstRunGate: Identifiable {
    /// The whole first-run flow, for an install that has answered nothing.
    case onboarding
    /// The safety terms alone, for somebody who onboarded before they existed —
    /// no record means never asked, and never asked means ask.
    case safety

    var id: Self {
        self
    }

    /// What `profiles` and `consent` between them say is still outstanding.
    @MainActor
    static func pending(profiles: ProfileStore, consent: SafetyConsentStore) -> Self? {
        guard profiles.hasCompletedOnboarding else { return .onboarding }
        return consent.needsConsent ? .safety : nil
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
