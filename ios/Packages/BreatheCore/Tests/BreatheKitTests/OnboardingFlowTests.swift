@testable import BreatheKit
import Foundation
import Testing

/// Drives the real stepper and the real store through the `ProfileWriting`
/// seam. What is under test is the promise that onboarding finishes without a
/// server: the flow is the only screen a first-run user cannot get past.
@MainActor
@Suite("Onboarding")
struct OnboardingFlowTests {
    /// Records what it was asked to send, and can be told to refuse — which is
    /// what a first launch on a train looks like.
    private final class RecordingWriter: ProfileWriting, @unchecked Sendable {
        private(set) var sent: [Profile] = []
        var isReachable = true

        @discardableResult
        func update(_ profile: Profile) async throws -> Profile {
            guard isReachable else {
                throw ProfileRepositoryError.transport("offline")
            }
            sent.append(profile)
            return profile
        }
    }

    /// A `UserDefaults` nobody else shares, so a test cannot read another's
    /// answers or the developer's own.
    private func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "onboarding-tests.\(name)")
        // Suites persist between runs; a stale one would make the first
        // assertion in every test depend on the previous run.
        suite?.removePersistentDomain(forName: "onboarding-tests.\(name)")
        return suite ?? .standard
    }

    @Test("The stepper walks the questions in order and back again")
    func walksTheSteps() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("steps"))
        let model = OnboardingModel(store: store)

        #expect(model.step == .welcome)
        model.advance()
        #expect(model.step == .goals)
        model.advance()
        #expect(model.step == .experience)

        // The one question with a required answer: without it, Next does
        // nothing rather than skipping past.
        #expect(!model.canAdvance)
        model.advance()
        #expect(model.step == .experience)

        model.experienceLevel = .new
        model.advance()
        #expect(model.step == .reminders)

        model.back()
        #expect(model.step == .experience)
    }

    /// Goals are sent in the order they were picked, so someone sees their own
    /// ordering back. A `Set` would look identical here and lose it.
    @Test("Toggling goals keeps the order they were picked in")
    func keepsGoalOrder() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("goals"))
        let model = OnboardingModel(store: store)

        model.toggle(.focus)
        model.toggle(.calm)
        model.toggle(.sleep)
        model.toggle(.calm)

        #expect(model.goals == [.focus, .sleep])
        #expect(!model.isSelected(.calm))
    }

    /// Never has to be what someone gets by not answering, all the way through
    /// to what is stored. The whole privacy stance rests on the default rather
    /// than on anyone making a choice.
    @Test("An untouched reminder dial stores never")
    func remindersDefaultToNever() {
        let writer = RecordingWriter()
        let store = ProfileStore(profiles: writer, defaults: defaults("reminders"))
        let model = OnboardingModel(store: store)

        model.experienceLevel = .regular
        #expect(model.reminderIntensity == .never)
        #expect(model.profile.reminderIntensity == .never)
    }

    /// The server rejects a longer note outright, so a field that let someone
    /// keep typing would trade an invisible limit for a save that fails after
    /// the fact.
    @Test("A note is held at the length the server accepts")
    func clampsTheIntentNote() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("note"))
        let model = OnboardingModel(store: store)

        model.intentNote = String(repeating: "a", count: Profile.maxIntentNoteLength + 50)

        #expect(model.intentNote.count == Profile.maxIntentNoteLength)
        #expect(model.profile.intentNote.count == Profile.maxIntentNoteLength)
    }

    /// The limit counts Unicode scalars because the server and the database do.
    /// A grapheme count would wave through a note of multi-scalar emoji — one
    /// 👨‍👩‍👧 is five scalars — that the server then rejects, leaving the profile
    /// retrying its sync forever.
    @Test("The note limit counts what the server counts")
    func clampsTheIntentNoteByUnicodeScalars() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("note-scalars"))
        let model = OnboardingModel(store: store)
        let family = "👨‍👩‍👧"

        model.intentNote = String(repeating: family, count: 150)

        #expect(model.intentNote.unicodeScalars.count <= Profile.maxIntentNoteLength)
        #expect(model.intentNote.count < 150, "the clamp fired before 150 graphemes")
    }

    /// The offline promise, and the reason the completion flag is local: the
    /// person is through the flow and into the app, and the answers are waiting
    /// to be sent rather than lost.
    @Test("Onboarding completes with no network, and syncs later")
    func completesOfflineAndSyncsLater() async {
        let writer = RecordingWriter()
        writer.isReachable = false

        let store = ProfileStore(profiles: writer, defaults: defaults("offline"))
        let model = OnboardingModel(store: store)

        model.toggle(.sleep)
        model.experienceLevel = .occasional
        model.reminderIntensity = .gentle
        model.intentNote = "  I wake up at three  "

        store.complete(with: model.profile)

        #expect(store.hasCompletedOnboarding)
        #expect(store.isPendingSync)
        #expect(store.profile.goals == [.sleep])
        // Trimmed on the way in, so the local copy and the server's cannot
        // differ by whitespace and leave the sync flag flapping.
        #expect(store.profile.intentNote == "I wake up at three")

        await store.syncIfNeeded()
        #expect(store.isPendingSync, "a failed send stays outstanding")
        #expect(writer.sent.isEmpty)

        writer.isReachable = true
        await store.syncIfNeeded()

        #expect(!store.isPendingSync)
        #expect(writer.sent.count == 1)
        #expect(writer.sent.first?.experienceLevel == .occasional)
    }

    /// A second launch must not ask the questions again, and must not re-send
    /// answers the server already has.
    @Test("A completed profile survives a relaunch")
    func survivesRelaunch() async {
        let writer = RecordingWriter()
        let suite = defaults("relaunch")

        let first = ProfileStore(profiles: writer, defaults: suite)
        first.complete(with: Profile(
            goals: [.energy],
            experienceLevel: .new,
            reminderIntensity: .daily,
            intentNote: "mornings"
        ))
        await first.syncIfNeeded()

        let second = ProfileStore(profiles: writer, defaults: suite)

        #expect(second.hasCompletedOnboarding)
        #expect(!second.isPendingSync)
        #expect(second.profile.goals == [.energy])
        #expect(second.profile.reminderIntensity == .daily)

        await second.syncIfNeeded()
        #expect(writer.sent.count == 1, "nothing outstanding means nothing sent")
    }
}
