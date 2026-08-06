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
    /// the journey's sync has one place to drain.
    private let sessions: any SessionRecording = FileSessionStore()

    /// Controlled-pause scores, kept beside the sessions and for the same
    /// reason — the journey tab reads them with no network at all.
    private let scores: any BoltScoreRecording = FileBoltScoreStore()

    /// In the environment rather than passed down, because the cue picker on the
    /// detail screen and the session that reads the setting are not adjacent.
    @State private var settings = SessionSettings()

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

    /// Totals, streaks, and the boards. Local-first: everything it shows about
    /// this person is folded from the two stores above, so the tab is complete
    /// before the sync it starts has finished.
    @State private var journey: JourneyModel

    init() {
        let identity = identity
        let baseURL = AppConfiguration.apiBaseURL

        let techniques = TechniqueRepository(baseURL: baseURL, identity: identity)
        _catalogue = State(wrappedValue: TechniqueListModel(techniques: techniques))
        _foundations = State(wrappedValue: FoundationsModel(topics: techniques))

        let profiles = ProfileStore(
            profiles: ProfileRepository(baseURL: baseURL, identity: identity)
        )
        _profiles = State(wrappedValue: profiles)
        _isOnboarding = State(wrappedValue: !profiles.hasCompletedOnboarding)

        let journeys = JourneyRepository(baseURL: baseURL, identity: identity)
        let sessions = sessions
        let scores = scores
        _journey = State(
            wrappedValue: JourneyModel(
                sessions: sessions,
                scores: scores,
                journeys: journeys,
                queue: SessionSyncQueue(sessions: sessions, scores: scores, journeys: journeys)
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
                    SettingsView()
                }
            }
            .tint(Theme.Accent.brand)
            // The palette resolves per appearance through the asset catalogue,
            // so one override here re-themes every screen; nil follows the
            // system, which keeps the default behaviour exactly today's.
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(settings)
            .fullScreenCover(isPresented: $isOnboarding) {
                OnboardingView(model: OnboardingModel(store: profiles)) {
                    isOnboarding = false
                }
            }
            // Answers given with no signal reach the server on a later launch.
            // Cheap when there is nothing outstanding, which is every launch
            // after the first — and the same is true of the sessions recorded
            // while it was unreachable.
            // Concurrently: neither depends on the other, and the journey drain
            // should not wait out a profile request's timeout to start.
            .task {
                async let profile: Void = profiles.syncIfNeeded()
                async let sessions: Void = journey.sync()
                _ = await (profile, sessions)
            }
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
