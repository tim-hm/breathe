import Foundation
import Observation

/// Drives the first-run stepper: which question is on screen, what has been
/// answered, and what happens at the end.
///
/// Lives in `OndKit` rather than the app target so the flow is testable on
/// the host — the app target has no test bundle, and a stepper whose transitions
/// nobody can exercise is where a screen someone cannot get past comes from.
@MainActor
@Observable
public final class OnboardingModel {
    /// The questions, in the order they are asked.
    ///
    /// An enum with an ordinal rather than an index into an array of views: the
    /// progress indicator, the back button, and the save all need to know where
    /// they are, and a raw `Int` would let them disagree.
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        /// Says what the app is for before asking anything.
        case welcome
        case goals
        case experience
        /// Age band, gender, and a note for the coach — every part of it
        /// optional, and "rather not say" already selected. After the breathing
        /// questions so it reads as tuning the coach rather than as a form to
        /// get through.
        case about
        /// The reminder dial. Ordered after the questions about breathing so it
        /// reads as a preference rather than as the price of entry, and last so
        /// that saving happens on the way out of it.
        case reminders
        /// Everything is saved; the way out.
        case done

        public var id: Self {
            self
        }

        /// The steps that ask something — what a step indicator counts.
        /// `welcome` is a greeting and `done` a confirmation; neither is a
        /// question to be part-way through.
        public static let questions: [Step] = [.goals, .experience, .about, .reminders]
    }

    public private(set) var step: Step = .welcome

    /// In the order they were picked, which is the order they are shown back.
    public private(set) var goals: [TechniqueGoal] = []
    public var experienceLevel: ExperienceLevel?
    public var reminderIntensity: ReminderIntensity = .never
    public var birthYearBand: BirthYearBand?
    public var gender: Gender?

    /// Why they are here, in their own words. Clamped as it is typed — the
    /// same rule the leaderboard name follows, in the unit
    /// `String.clamped(toScalars:)` explains — so the field stops accepting
    /// input rather than letting someone write past the point where saving
    /// would fail.
    public var intentNote: String = "" {
        didSet {
            let clamped = intentNote.clamped(toScalars: Profile.maxIntentNoteLength)
            if clamped != intentNote {
                intentNote = clamped
            }
        }
    }

    private let store: ProfileStore
    private let schedules: ScheduleStore?
    private let catalogue: TechniqueListModel?

    /// - Parameters:
    ///   - schedules: where a reminder the person asked for lands. Absent, the
    ///     dial is still stored on the profile and simply rings nothing.
    ///   - catalogue: what that reminder opens with. Also absent-able, and for
    ///     the same reason: onboarding has to finish with no network, and the
    ///     catalogue is a fetch.
    public init(
        store: ProfileStore,
        schedules: ScheduleStore? = nil,
        catalogue: TechniqueListModel? = nil
    ) {
        self.store = store
        self.schedules = schedules
        self.catalogue = catalogue
    }

    /// Whether this person has told the flow anything yet.
    ///
    /// Asked of the profile the answers make rather than field by field, so the
    /// question a restore turns on and the question asked of the server's copy
    /// are the same one — and a fourth question cannot make them disagree.
    public var hasAnswered: Bool {
        profile.hasAnswers
    }

    /// Adopts the answers the server already holds for this identity, closing
    /// the flow if it finds them.
    ///
    /// Runs *alongside* the questions rather than in front of them. The
    /// alternative — racing the fetch against a short timeout before drawing
    /// anything — puts a network wait between launch and the welcome screen for
    /// every genuinely new user, which is nearly all of them and none of whom
    /// have a profile to restore. Here the flow is on screen immediately, and
    /// somebody with no signal never learns this was attempted.
    ///
    /// - Returns: whether the flow should close, having adopted a profile.
    public func restoreIfPossible() async -> Bool {
        guard !hasAnswered else { return false }
        guard let restored = await store.restoredProfile() else { return false }

        // Asked again on the way back: the request was in flight while the
        // person could answer, and an answer given here is both the more recent
        // of the two and the one they are looking at.
        guard !hasAnswered else { return false }

        store.adopt(restored)
        return true
    }

    /// Adds or removes a goal, keeping the order the person picked in.
    public func toggle(_ goal: TechniqueGoal) {
        if let index = goals.firstIndex(of: goal) {
            goals.remove(at: index)
        } else {
            goals.append(goal)
        }
    }

    public func isSelected(_ goal: TechniqueGoal) -> Bool {
        goals.contains(goal)
    }

    /// Whether the current step has the answer it asks for.
    ///
    /// Goals and experience want one before Next lights up — not as a wall,
    /// but so that Next always means "that's my answer"; Skip is the way past
    /// without one. Reminders and the about step arrive already answered:
    /// `never` and "rather not say" are selected before anyone touches them.
    public var canAdvance: Bool {
        switch step {
        case .goals: !goals.isEmpty
        case .experience: experienceLevel != nil
        default: true
        }
    }

    /// Whether the current step can be passed by unanswered. True exactly
    /// where `canAdvance` can be false: a question that insists on an answer
    /// and offers no way around it is a wall, and a Skip on any other step
    /// would be a second Next.
    public var canSkip: Bool {
        step == .goals || step == .experience
    }

    /// Moves to the next question, saving on the way out of the last one.
    public func advance() {
        guard canAdvance else { return }
        moveOn()
    }

    /// Passes an optional question by without answering it. The answer given
    /// so far is kept — skipping is declining to finish, not undoing.
    public func skip() {
        guard canSkip else { return }
        moveOn()
    }

    private func moveOn() {
        if step == .reminders {
            store.complete(with: profile)
            seedReminder()
            // Not awaited: the person is one tap from breathing, and the upload
            // has a whole app lifetime to succeed in. `ProfileStore` has already
            // written the answers and closed onboarding by this point.
            Task { await store.syncIfNeeded() }
        }

        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    /// Makes the reminder the dial asked for, once.
    ///
    /// `never` falls out through `ReminderSeed.schedule` returning nil, so
    /// nothing is created and `ScheduleStore.add` — the one place notification
    /// permission is ever requested — is not reached at all.
    ///
    /// Only ever seeds into an empty list: somebody who already keeps schedules
    /// has an arrangement of their own, and a flow that has just asked one
    /// question about reminders is not entitled to add to it.
    ///
    /// Waits for the catalogue rather than reading whatever it holds at this
    /// instant, because a reminder can only name a technique the app has heard
    /// of and this runs on a first launch — the one launch where the fetch may
    /// still be in the air. Joining the shared load rather than starting a fetch
    /// of its own, and not awaited, so the person is still one tap from
    /// breathing.
    private func seedReminder() {
        guard let schedules, schedules.schedules.isEmpty, let catalogue else { return }
        let goal = goals.first ?? .calm
        let intensity = reminderIntensity

        Task {
            await catalogue.loadIfNeeded()

            guard case let .loaded(techniques) = catalogue.state,
                  // Calm where they skipped the goals question: the seed is a
                  // starting point to edit rather than a claim about them, and
                  // it is the one goal that suits an unknown reason for being
                  // here.
                  let technique = HomeSuggestion.technique(
                      for: goal,
                      techniques: techniques,
                      history: []
                  ),
                  let seeded = ReminderSeed.schedule(for: intensity, technique: technique)
            else {
                return
            }

            schedules.add(seeded)
        }
    }

    /// Whether there is a question behind this one to return to.
    ///
    /// False on the welcome screen, which has nothing before it, and on `.done`,
    /// where the answers are already saved and going back would offer to change
    /// something that has been sent. Exposed rather than left to `back()` alone
    /// because the view needs the same answer for the button it draws.
    public var canGoBack: Bool {
        step != .welcome && step != .done
    }

    public func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// How far through, for a progress indicator. Excludes `.done`, which is a
    /// confirmation rather than a question.
    public var progress: Double {
        let questions = Double(Step.allCases.count - 1)
        return Double(step.rawValue) / questions
    }

    /// The answers as they stand. The display name is absent on purpose — the
    /// flow never asks for one, and the leaderboard screen owns it.
    public var profile: Profile {
        Profile(
            goals: goals,
            experienceLevel: experienceLevel,
            reminderIntensity: reminderIntensity,
            intentNote: intentNote,
            birthYearBand: birthYearBand,
            gender: gender
        )
    }
}
