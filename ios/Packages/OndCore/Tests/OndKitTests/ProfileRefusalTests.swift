import Foundation
@testable import OndKit
import Testing

/// What a server that *refuses* answers does to the device that sent them, as
/// opposed to one that cannot be reached.
///
/// The two look identical from a `catch` and are opposites in every other way. A
/// connection comes back, so an unsent profile is worth keeping and retrying; a
/// judgement does not, so the same retry is a doomed request on every cold
/// launch for the life of the install — under a screen showing the refused value
/// as saved.
@MainActor
@Suite("A profile the server refuses")
struct ProfileRefusalTests {
    private nonisolated static let reason = "display_name must be at least 2 characters"

    /// Refuses every write and counts the attempts, which is how a retry that
    /// should not happen is caught.
    private final class RefusingProfiles: ProfileSyncing, @unchecked Sendable {
        private(set) var attempts = 0

        func fetch() async throws -> Profile {
            .unanswered
        }

        @discardableResult
        func update(_: Profile) async throws -> Profile {
            attempts += 1
            throw ProfileRepositoryError.rejected(ProfileRefusalTests.reason)
        }
    }

    /// Stands in for no signal: the same `catch`, the opposite conclusion.
    private struct UnreachableProfiles: ProfileSyncing {
        func fetch() async throws -> Profile {
            .unanswered
        }

        @discardableResult
        func update(_: Profile) async throws -> Profile {
            throw ProfileRepositoryError.transport("offline")
        }
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "profile-refusal-tests.\(name)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("a defaults suite is available")
            return .standard
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func named(_ displayName: String) -> Profile {
        var profile = Profile.unanswered
        profile.displayName = displayName
        return profile
    }

    @Test("A refusal stops the retry rather than outliving the install")
    func aRefusalClearsTheOutstandingWrite() async {
        let server = RefusingProfiles()
        let suite = defaults("stops-retrying")
        let store = ProfileStore(profiles: server, defaults: suite)

        await store.save(named("a"))

        #expect(store.syncState == .rejected(Self.reason))
        #expect(!store.isPendingSync)

        // A second launch over the same defaults, because the failure the flag
        // caused was a request per launch rather than one per call.
        let relaunched = ProfileStore(profiles: server, defaults: suite)
        #expect(!relaunched.isPendingSync)

        await relaunched.syncIfNeeded()
        #expect(server.attempts == 1, "nothing retries a judgement")
    }

    @Test("The name the server refused is not shown back as the saved one")
    func aRefusedNameIsNotReflectedBack() async {
        let store = ProfileStore(profiles: RefusingProfiles(), defaults: defaults("refused-name"))
        let model = LeaderboardNameModel(store: store)

        model.displayName = "Tim"
        await model.save()

        #expect(model.rejection == Self.reason)
        #expect(!model.isSaving)
    }

    /// The other half of the same rule: no signal is not a refusal, so the
    /// answer stays outstanding and the screen says nothing.
    @Test("An unreachable server leaves the answers outstanding and unexplained")
    func anUnreachableServerIsNotARefusal() async {
        let store = ProfileStore(
            profiles: UnreachableProfiles(),
            defaults: defaults("unreachable")
        )
        let model = LeaderboardNameModel(store: store)

        model.displayName = "Tim"
        await model.save()

        #expect(model.rejection == nil)
        #expect(store.isPendingSync)
        #expect(store.profile.displayName == "Tim")
    }
}
