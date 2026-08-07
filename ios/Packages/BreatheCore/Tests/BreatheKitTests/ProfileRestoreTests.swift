@testable import BreatheKit
import Foundation
import Testing

/// What happens on a launch with no local answers, where the Keychain identity
/// says the app has met this person before.
///
/// Worth testing because both mistakes are silent. Failing to adopt asks
/// somebody every question again and then overwrites the profile they already
/// had; adopting too eagerly throws away answers they are in the middle of
/// giving, and neither leaves anything on screen to say so.
@MainActor
@Suite("Restoring a profile on first launch")
struct ProfileRestoreTests {
    /// A server holding whatever the test says it holds, which can be told to
    /// refuse — a first launch with no signal.
    private final class StandingProfiles: ProfileSyncing, @unchecked Sendable {
        var held: Profile
        var isReachable = true
        private(set) var sent: [Profile] = []

        init(held: Profile = .unanswered) {
            self.held = held
        }

        func fetch() async throws -> Profile {
            guard isReachable else {
                throw ProfileRepositoryError.transport("offline")
            }
            return held
        }

        @discardableResult
        func update(_ profile: Profile) async throws -> Profile {
            guard isReachable else {
                throw ProfileRepositoryError.transport("offline")
            }
            sent.append(profile)
            return profile
        }
    }

    /// Answers the fetch only once the test lets it, so an answer can be given
    /// while the request is in flight — the race the precedence rule exists for.
    private final class PausedProfiles: ProfileSyncing, @unchecked Sendable {
        var held: Profile
        private(set) var isFetching = false
        var isReleased = false

        init(held: Profile) {
            self.held = held
        }

        func fetch() async throws -> Profile {
            isFetching = true
            while !isReleased {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return held
        }

        @discardableResult
        func update(_ profile: Profile) async throws -> Profile {
            profile
        }
    }

    /// Polls until the restore has actually reached the server, so the answer
    /// the test then gives lands while the request is genuinely in flight.
    private func waitUntilFetching(_ server: PausedProfiles) async throws {
        for _ in 0 ..< 200 {
            if server.isFetching {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for the profile fetch")
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "profile-restore-tests.\(name)")
        suite?.removePersistentDomain(forName: "profile-restore-tests.\(name)")
        return suite ?? .standard
    }

    private var answered: Profile {
        Profile(
            goals: [.sleep, .calm],
            experienceLevel: .occasional,
            reminderIntensity: .gentle,
            intentNote: ""
        )
    }

    /// The reinstall. Nothing is asked again, and nothing is sent — the answers
    /// came from the server, so pushing them back would be a write nobody made
    /// and the exact overwrite this closes.
    @Test("Answers the server already holds close the flow instead of re-asking")
    func adoptsARestoredProfile() async {
        let server = StandingProfiles(held: answered)
        let store = ProfileStore(profiles: server, defaults: defaults("adopt"))
        let model = OnboardingModel(store: store)

        #expect(await model.restoreIfPossible())
        #expect(store.hasCompletedOnboarding)
        #expect(store.profile == answered)
        #expect(!store.isPendingSync)

        await store.syncIfNeeded()
        #expect(server.sent.isEmpty, "a restored profile is not echoed back")
    }

    /// A person the app really has not met. The server answers — it creates the
    /// row on first sight — and the answer is an empty profile, which is not a
    /// reason to skip the questions.
    @Test("A profile of no answers is not a restore")
    func aNewPersonStillGetsAsked() async {
        let store = ProfileStore(profiles: StandingProfiles(), defaults: defaults("new"))
        let model = OnboardingModel(store: store)

        #expect(await !model.restoreIfPossible())
        #expect(!store.hasCompletedOnboarding)
        #expect(model.step == .welcome)
    }

    /// The offline promise, from the other side: the attempt fails, and the
    /// person is looking at the first question either way.
    @Test("No signal is not an error, only no restore")
    func offlineFallsThroughToTheFlow() async {
        let server = StandingProfiles(held: answered)
        server.isReachable = false
        let store = ProfileStore(profiles: server, defaults: defaults("offline"))
        let model = OnboardingModel(store: store)

        #expect(await !model.restoreIfPossible())
        #expect(!store.hasCompletedOnboarding)
    }

    /// The race the whole design turns on. The flow is drawn immediately and the
    /// fetch runs behind it, so a slow server can answer after somebody has
    /// started answering — and what they are looking at has to win.
    @Test("An answer given while the request is in flight beats the restore")
    func aHalfAnsweredFlowIsNeverClobbered() async throws {
        let server = PausedProfiles(held: answered)
        let store = ProfileStore(profiles: server, defaults: defaults("race"))
        let model = OnboardingModel(store: store)

        let restore = Task { await model.restoreIfPossible() }

        try await waitUntilFetching(server)

        model.toggle(.energy)
        server.isReleased = true

        #expect(await !restore.value)
        #expect(!store.hasCompletedOnboarding)
        #expect(model.goals == [.energy], "their answer, not the server's")
    }

    /// A completed local flow owns the answers outright: this launch is not the
    /// one that lost them, and a fetch here could only overwrite a fresher
    /// profile with an older one.
    @Test("A finished flow is never restored over")
    func aCompletedProfileIsLeftAlone() async {
        let server = StandingProfiles(held: answered)
        let store = ProfileStore(profiles: server, defaults: defaults("completed"))
        let mine = Profile(
            goals: [.focus],
            experienceLevel: .regular,
            reminderIntensity: .never,
            intentNote: ""
        )

        store.complete(with: mine)
        #expect(await store.restoredProfile() == nil)
        #expect(store.profile == mine)
    }
}
