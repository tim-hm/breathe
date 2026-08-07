import Foundation
@testable import OndKit
import Testing

/// The display-name rule, pinned in the unit the server counts in.
///
/// This is the failure the same rule on the intent note was written to prevent:
/// a client that clamps by a different measure than the server produces a
/// profile whose every sync is rejected, forever, with nothing on screen to say
/// so.
@Suite("Leaderboard name")
@MainActor
struct LeaderboardNameTests {
    private struct AcceptingProfiles: ProfileSyncing {
        func fetch() async throws -> Profile {
            .unanswered
        }

        func update(_ profile: Profile) async throws -> Profile {
            profile
        }
    }

    /// Stands in for a server that already holds the name and hands back the
    /// suffixed one it stored instead.
    private struct SuffixingProfiles: ProfileSyncing {
        func fetch() async throws -> Profile {
            .unanswered
        }

        func update(_ profile: Profile) async throws -> Profile {
            var stored = profile
            stored.displayName = "\(profile.displayName)·2"
            return stored
        }
    }

    private func store(_ profiles: any ProfileSyncing = AcceptingProfiles()) -> ProfileStore {
        let name = "leaderboard-name-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("a defaults suite is available")
            return ProfileStore(profiles: profiles)
        }
        defaults.removePersistentDomain(forName: name)
        return ProfileStore(profiles: profiles, defaults: defaults)
    }

    @Test("A name is clamped by Unicode scalars, as the server counts it")
    func clampingCountsScalars() {
        let model = LeaderboardNameModel(store: store())

        model.displayName = String(repeating: "🌊", count: Profile.maxDisplayNameLength + 10)

        #expect(model.displayName.unicodeScalars.count == Profile.maxDisplayNameLength)
        #expect(model.displayName.allSatisfy { $0 == "🌊" }, "no scalar was split in half")
    }

    /// Clearing a name means leaving the boards, so it can never be refused —
    /// and a single character can, because the server's minimum is two.
    @Test("Empty always saves; too short never does")
    func emptyIsAlwaysAllowed() {
        let model = LeaderboardNameModel(store: store())

        model.displayName = ""
        #expect(model.canSave)

        model.displayName = "   "
        #expect(model.canSave, "whitespace is somebody deleting their name")

        model.displayName = "a"
        #expect(!model.canSave)

        model.displayName = "Tim"
        #expect(model.canSave)
    }

    /// The name the server stored is the name other people see, so it has to
    /// replace what was typed rather than leave the screen disagreeing with the
    /// boards.
    @Test("A suffixed name comes back to the screen")
    func aSuffixedNameIsReflectedBack() async {
        let model = LeaderboardNameModel(store: store(SuffixingProfiles()))

        model.displayName = "  Tim  "
        await model.save()

        #expect(model.displayName == "Tim·2")
        #expect(!model.isSaving)
    }
}
