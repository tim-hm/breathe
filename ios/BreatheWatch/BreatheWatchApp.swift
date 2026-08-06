import BreatheKit
import BreatheUI
import SwiftUI

/// The watch app's entry point, and the one place its dependencies are wired.
///
/// The same composition as the phone's, over the same types: the session engine,
/// the offline catalogue cache, the local session store, and the sync queue are
/// all platform-neutral by construction, so the wrist reuses them rather than
/// reimplementing them. Two things differ, and both are consequences of the
/// watch never minting an identity — the identity store is the provisioned one,
/// and a `PhoneLink` listens for the id that fills it.
@main
struct BreatheWatchApp: App {
    /// Empty until the phone has been in range once. Everything below tolerates
    /// that: the catalogue is a public RPC, sessions record locally, and the
    /// sync queue simply keeps its backlog until there is somebody to attribute
    /// it to.
    private let identity = ProvisionedUserIdentityStore()

    /// One store for the whole app, and the same file the sync queue drains.
    private let sessions: any SessionRecording = FileSessionStore()

    @State private var catalogue: TechniqueListModel
    @State private var journey: JourneyModel
    @State private var phone: PhoneLink

    init() {
        let baseURL = WatchConfiguration.apiBaseURL

        _catalogue = State(
            wrappedValue: TechniqueListModel(
                techniques: CachedTechniqueRepository(
                    caching: TechniqueRepository(baseURL: baseURL, identity: identity)
                )
            )
        )

        let journeys = JourneyRepository(baseURL: baseURL, identity: identity)
        // Present so the queue and the model are the ones the phone uses,
        // unchanged. It stays empty on the wrist: the BOLT test is a phone
        // screen, and the number it produces reaches here over the pairing.
        let scores = FileBoltScoreStore()
        _journey = State(
            wrappedValue: JourneyModel(
                sessions: sessions,
                scores: scores,
                journeys: journeys,
                queue: SessionSyncQueue(sessions: sessions, scores: scores, journeys: journeys)
            )
        )

        _phone = State(wrappedValue: PhoneLink(identity: identity))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TechniqueCarouselView(model: catalogue, sessions: sessions, journey: journey)
            }
            .tint(Theme.Accent.brand)
            // In the environment rather than passed down: the only screen that
            // reads the mirrored pause is two pushes from here, and the
            // catalogue in between has no use for it.
            .environment(phone)
            .task {
                phone.activate()
                await journey.sync()
            }
            // An identity arriving is the moment a backlog recorded anonymously
            // becomes attributable — and, the first time, the moment the phone's
            // own history can be restored onto the wrist.
            .onChange(of: phone.userId) { _, userId in
                guard userId != nil else { return }
                Task { await journey.sync() }
            }
        }
    }
}
