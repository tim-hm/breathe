import BreatheKit
import BreatheUI
import SwiftUI

@main
struct BreatheApp: App {
    /// This install's anonymous id, minted on first use and read from the
    /// Keychain thereafter. Built here and handed to every repository, so one
    /// person is one identity across the whole app.
    private let identity: any UserIdentityStore = KeychainUserIdentityStore()

    /// Built once, at the composition root, and handed down. Views receive a
    /// `TechniqueReading` rather than constructing their own, so a preview or a
    /// test can substitute one without touching the network.
    private let techniques: any TechniqueReading

    /// One store for the whole app: every session ends up in the same file, and
    /// M5's sync has one place to drain.
    private let sessions: any SessionRecording = FileSessionStore()

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
    /// are two views onto the same load.
    @State private var catalogue: TechniqueListModel

    /// The basics, shared the same way — reference data loaded once.
    @State private var foundations: FoundationsModel

    init() {
        let identity = identity
        let baseURL = AppConfiguration.apiBaseURL

        let techniques = TechniqueRepository(baseURL: baseURL, identity: identity)
        self.techniques = techniques
        _catalogue = State(wrappedValue: TechniqueListModel(techniques: techniques))
        _foundations = State(wrappedValue: FoundationsModel(topics: techniques))

        let profiles = ProfileStore(
            profiles: ProfileRepository(baseURL: baseURL, identity: identity)
        )
        _profiles = State(wrappedValue: profiles)
        _isOnboarding = State(wrappedValue: !profiles.hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            // The chrome future features land in: journey joins as a tab (M5),
            // reminders and the subscription live under Settings (M7, M8).
            TabView {
                Tab("Breathe", systemImage: "smallcircle.filled.circle") {
                    HomeView(model: catalogue, sessions: sessions)
                }
                Tab("Techniques", systemImage: "square.grid.2x2") {
                    TechniqueListView(
                        model: catalogue,
                        foundations: foundations,
                        sessions: sessions
                    )
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView()
                }
            }
            .tint(Theme.Accent.brand)
            .environment(settings)
            .fullScreenCover(isPresented: $isOnboarding) {
                OnboardingView(model: OnboardingModel(store: profiles)) {
                    isOnboarding = false
                }
            }
            // Answers given with no signal reach the server on a later launch.
            // Cheap when there is nothing outstanding, which is every launch
            // after the first.
            .task { await profiles.syncIfNeeded() }
        }
    }
}
