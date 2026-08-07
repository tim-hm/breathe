import BreatheKit
import BreatheUI
import SwiftUI

@main
struct BreatheApp: App {
    /// This install's anonymous id, minted on first use and read from the
    /// Keychain thereafter. Built here and handed to every repository, so one
    /// person is one identity across the whole app.
    private let identity: any UserIdentityStore = KeychainUserIdentityStore()

    /// One store for the whole app: every session ends up in the same file, and
    /// the journey's sync has one place to drain. Concrete rather than `any
    /// SessionRecording`, because the sync queue also needs its other face —
    /// the tombstones deletions wait in until the server confirms them.
    private let sessions = FileSessionStore()

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

    /// Whether this person has Breathe Plus. In the environment for the same
    /// reason `settings` is: the surfaces that offer a subscription — the
    /// assistant's two strips, and the paywall they open — are nowhere near
    /// here, and threading a parameter through every screen between would touch
    /// every one of them.
    @State private var plus: SubscriptionStore

    /// Holds the onboarding answers and knows whether they have been given.
    @State private var profiles: ProfileStore

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
    /// so the store outlives the Settings tab that edits it — the notifications
    /// have to stay honest whether or not the screen is ever opened.
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
        watch = WatchLink(identity: identity, scores: scores)

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

        _plus = State(
            wrappedValue: SubscriptionStore(
                front: StoreKitStoreFront(),
                entitlements: EntitlementRepository(baseURL: baseURL, identity: identity)
            )
        )

        let journeys = JourneyRepository(baseURL: baseURL, identity: identity)
        let sessions = sessions
        let scores = scores
        _journey = State(
            wrappedValue: JourneyModel(
                sessions: sessions,
                scores: scores,
                journeys: journeys,
                queue: SessionSyncQueue(
                    sessions: sessions,
                    scores: scores,
                    journeys: journeys,
                    tombstones: sessions
                )
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            // The chrome future features land in: reminders and the
            // subscription live under Settings (M7, M8).
            TabView {
                Tab("Breathe", systemImage: "smallcircle.filled.circle") {
                    HomeView(model: catalogue, sessions: sessions)
                }
                Tab("Techniques", systemImage: "square.grid.2x2") {
                    TechniqueListView(model: catalogue, sessions: sessions)
                }
                Tab("Journey", systemImage: "clock.arrow.circlepath") {
                    JourneyView(model: journey, profiles: profiles, catalogue: catalogue)
                }
                Tab("The basics", systemImage: "book") {
                    NavigationStack {
                        FoundationsView(model: foundations)
                    }
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView(schedules: schedules, catalogue: catalogue)
                }
            }
            .tint(Theme.Accent.brand)
            // The palette resolves per appearance through the asset catalogue,
            // so one override here re-themes every screen; nil follows the
            // system, which keeps the default behaviour exactly today's.
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(settings)
            .environment(plus)
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
    /// system. Mapped here rather than in BreatheKit so the domain package
    /// stays free of SwiftUI — the same seam `GoalAccent` sits on.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
