@testable import BreatheKit
import Foundation
import Testing

/// Drives the real stepper and the real store through the `ProfileSyncing`
/// seam. What is under test is the promise that onboarding finishes without a
/// server: the flow is the only screen a first-run user cannot get past.
@MainActor
@Suite("Onboarding")
struct OnboardingFlowTests {
    /// Records what it was asked to send, and can be told to refuse — which is
    /// what a first launch on a train looks like.
    private final class RecordingWriter: ProfileSyncing, @unchecked Sendable {
        private(set) var sent: [Profile] = []
        var isReachable = true

        func fetch() async throws -> Profile {
            guard isReachable else {
                throw ProfileRepositoryError.transport("offline")
            }
            return .unanswered
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

        // Next waits for an answer on the questions that want one; without it,
        // advancing does nothing rather than silently skipping past.
        #expect(!model.canAdvance)
        model.advance()
        #expect(model.step == .goals)

        model.toggle(.calm)
        model.advance()
        #expect(model.step == .experience)

        #expect(!model.canAdvance)
        model.experienceLevel = .new
        model.advance()
        #expect(model.step == .about)

        // The about step arrives already answered — "rather not say" is
        // selected — so Next is never waiting on it.
        #expect(model.canAdvance)
        model.advance()
        #expect(model.step == .reminders)

        model.back()
        #expect(model.step == .about)
        model.back()
        #expect(model.step == .experience)
    }

    /// Skip is the way past a question Next is still waiting on, and only
    /// those: everywhere else it would be a second Next, so it refuses.
    @Test("Skip passes an unanswered question without touching the others")
    func skipsUnansweredQuestions() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("skip"))
        let model = OnboardingModel(store: store)

        #expect(!model.canSkip, "the welcome screen has nothing to skip")
        model.skip()
        #expect(model.step == .welcome)

        model.advance()
        #expect(model.canSkip)
        model.skip()
        #expect(model.step == .experience)

        model.skip()
        #expect(model.step == .about)
        #expect(!model.canSkip, "the about step is already answered — Next is the way on")

        model.skip()
        #expect(model.step == .about)
        model.advance()
        #expect(model.step == .reminders)
        #expect(!model.canSkip, "reminders is already answered — Next is the way on")

        model.skip()
        #expect(model.step == .reminders)
        #expect(model.profile.goals.isEmpty)
        #expect(model.profile.experienceLevel == nil)
        #expect(model.profile.birthYearBand == nil)
        #expect(model.profile.gender == nil)
        #expect(model.profile.intentNote.isEmpty)
    }

    /// Skipping declines to finish a question, not to have started it: an
    /// answer already given survives the skip.
    @Test("Skip keeps the answer given so far")
    func skipKeepsPartialAnswers() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("skip-keep"))
        let model = OnboardingModel(store: store)

        model.advance()
        model.toggle(.sleep)
        model.skip()

        #expect(model.step == .experience)
        #expect(model.profile.goals == [.sleep])
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

    /// The about step's answers reach the profile the flow saves — all three of
    /// them, because a field collected and then dropped on the way out would
    /// look identical to one never asked.
    @Test("The about step's answers flow into the saved profile")
    func aboutAnswersReachTheProfile() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("about"))
        let model = OnboardingModel(store: store)

        model.birthYearBand = .eighties
        model.gender = .nonBinary
        model.intentNote = "I want to stop clenching my jaw"

        #expect(model.profile.birthYearBand == .eighties)
        #expect(model.profile.gender == .nonBinary)
        #expect(model.profile.intentNote == "I want to stop clenching my jaw")
    }

    /// The same clamp `LeaderboardNameModel` applies to the name, in the same
    /// unit: a note the server would refuse must be impossible to type.
    @Test("The intent note stops accepting input at the server's limit")
    func clampsTheIntentNote() {
        let store = ProfileStore(profiles: RecordingWriter(), defaults: defaults("clamp"))
        let model = OnboardingModel(store: store)

        model.intentNote = String(repeating: "a", count: Profile.maxIntentNoteLength + 40)

        #expect(model.intentNote.unicodeScalars.count == Profile.maxIntentNoteLength)
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

        store.complete(with: model.profile)

        #expect(store.hasCompletedOnboarding)
        #expect(store.isPendingSync)
        #expect(store.profile.goals == [.sleep])

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
