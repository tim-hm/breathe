import Foundation
@testable import OndKit
import Testing

/// Editing a profile after onboarding: the rules the server will enforce, and
/// the fields a change has to carry.
///
/// The clamping tests are the failure this whole seam was written to prevent: a
/// client that clamps by a different measure than the server produces a profile
/// whose every sync is rejected, forever, with nothing on screen to say so.
@Suite("Profile editing")
@MainActor
struct ProfileEditTests {
    private struct AcceptingProfiles: ProfileSyncing {
        func fetch() async throws -> Profile {
            .unanswered
        }

        func update(_ profile: Profile) async throws -> Profile {
            profile
        }
    }

    /// Keeps whatever it was last sent, so a test can read back the profile that
    /// actually went over the wire rather than the one the store holds.
    private final class RecordingProfiles: ProfileSyncing, @unchecked Sendable {
        private(set) var received: Profile?

        func fetch() async throws -> Profile {
            .unanswered
        }

        func update(_ profile: Profile) async throws -> Profile {
            received = profile
            return profile
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
        let name = "profile-edit-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("a defaults suite is available")
            return ProfileStore(profiles: profiles)
        }
        defaults.removePersistentDomain(forName: name)
        return ProfileStore(profiles: profiles, defaults: defaults)
    }

    @Test("A name is clamped by Unicode scalars, as the server counts it")
    func clampingCountsScalars() {
        let model = ProfileEditModel(store: store())

        model.draft.displayName = String(
            repeating: "🌊",
            count: Profile.maxDisplayNameLength + 10
        )

        #expect(model.draft.displayName.unicodeScalars.count == Profile.maxDisplayNameLength)
        #expect(model.draft.displayName.allSatisfy { $0 == "🌊" }, "no scalar was split in half")
    }

    /// The same rule on the other free-text field, which the coach reads and the
    /// column `CHECK` bounds.
    @Test("A coach note is clamped by the same measure")
    func aNoteIsClampedToo() {
        let model = ProfileEditModel(store: store())

        model.draft.intentNote = String(
            repeating: "🌊",
            count: Profile.maxIntentNoteLength + 10
        )

        #expect(model.draft.intentNote.unicodeScalars.count == Profile.maxIntentNoteLength)
    }

    /// Clearing a name means leaving the boards, so it can never be refused —
    /// and a single character can, because the server's minimum is two.
    @Test("Empty always saves; too short never does")
    func emptyIsAlwaysAllowed() {
        let model = ProfileEditModel(store: store())

        model.draft.displayName = ""
        #expect(model.canSave)

        model.draft.displayName = "   "
        #expect(model.canSave, "whitespace is somebody deleting their name")

        model.draft.displayName = "a"
        #expect(!model.canSave)

        model.draft.displayName = "Tim"
        #expect(model.canSave)
    }

    /// The name the server stored is the name other people see, so it has to
    /// replace what was typed rather than leave the screen disagreeing with the
    /// boards.
    @Test("A suffixed name comes back to the screen")
    func aSuffixedNameIsReflectedBack() async {
        let model = ProfileEditModel(store: store(SuffixingProfiles()))

        model.draft.displayName = "  Tim  "
        await model.save()

        #expect(model.draft.displayName == "Tim·2")
        #expect(!model.isSaving)
    }

    /// The goals list is an answer rather than a set: the coach's prompt reads
    /// it back "in their own order", so a re-pick has to land at the end rather
    /// than back where it first was.
    @Test("Goals keep the order they were picked in")
    func goalsKeepTheirOrder() {
        let model = ProfileEditModel(store: store())

        model.toggle(.sleep)
        model.toggle(.calm)
        #expect(model.draft.goals == [.sleep, .calm])

        model.toggle(.sleep)
        model.toggle(.sleep)
        #expect(model.draft.goals == [.calm, .sleep])
        #expect(model.isSelected(.sleep))
        #expect(!model.isSelected(.focus))
    }

    /// The point of the Settings screen: an answer given at onboarding can be
    /// changed afterwards and the change reaches the server. Every field at
    /// once, because `UpdateProfile` is a wholesale replacement — one that
    /// carried only the field the screen last touched would blank the rest.
    @Test("Every edited field reaches the server")
    func everyFieldSyncs() async throws {
        let server = RecordingProfiles()
        let profiles = store(server)
        profiles.complete(
            with: Profile(
                goals: [.calm],
                experienceLevel: .new,
                reminderIntensity: .never,
                intentNote: "sleeping badly"
            )
        )
        await profiles.syncIfNeeded()

        let model = ProfileEditModel(store: profiles)
        model.toggle(.calm)
        model.toggle(.focus)
        model.draft.experienceLevel = .regular
        model.draft.reminderIntensity = .daily
        model.draft.intentNote = "back to work"
        model.draft.displayName = "Tim"
        model.draft.birthYearBand = .eighties
        model.draft.gender = .male

        await model.save()

        let sent = try #require(server.received)
        #expect(sent.goals == [.focus])
        #expect(sent.experienceLevel == .regular)
        #expect(sent.reminderIntensity == .daily)
        #expect(sent.intentNote == "back to work")
        #expect(sent.displayName == "Tim")
        #expect(sent.birthYearBand == .eighties)
        #expect(sent.gender == .male)
        #expect(profiles.syncState == .settled)
    }
}
