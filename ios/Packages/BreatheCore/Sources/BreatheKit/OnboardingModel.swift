import Foundation
import Observation

/// Drives the first-run stepper: which question is on screen, what has been
/// answered, and what happens at the end.
///
/// Lives in `BreatheKit` rather than the app target so the flow is testable on
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
        /// The reminder dial. Ordered after the questions about breathing so it
        /// reads as a preference rather than as the price of entry.
        case reminders
        /// The free-text note. Optional, and the last thing asked.
        case intent
        /// Everything is saved; the way out.
        case done

        public var id: Self {
            self
        }
    }

    public private(set) var step: Step = .welcome

    /// In the order they were picked, which is the order they are shown back.
    public private(set) var goals: [TechniqueGoal] = []
    public var experienceLevel: ExperienceLevel?
    public var reminderIntensity: ReminderIntensity = .never

    /// Clamped to the length the server accepts, here rather than in the text
    /// field: the rule belongs to the answer, not to one way of typing it, and
    /// the app target has no test bundle to pin it in.
    ///
    /// Counted in Unicode scalars, not `Character`s, because that is what the
    /// server's validation and the column `CHECK` both count: a grapheme-cluster
    /// count would pass a note of multi-scalar emoji that the server then
    /// rejects, leaving the profile retrying its sync forever.
    public var intentNote = "" {
        didSet {
            let scalars = intentNote.unicodeScalars
            if scalars.count > Profile.maxIntentNoteLength {
                let end = scalars.index(scalars.startIndex, offsetBy: Profile.maxIntentNoteLength)
                intentNote = String(scalars[..<end])
            }
        }
    }

    private let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
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

    /// Whether the current step has an answer it insists on.
    ///
    /// Only the experience question does. Goals, reminders, and the note can all
    /// be left as they are — an onboarding that refuses to continue is a worse
    /// first impression than a profile with a blank in it.
    public var canAdvance: Bool {
        step != .experience || experienceLevel != nil
    }

    /// Moves to the next question, saving on the way out of the last one.
    public func advance() {
        guard canAdvance else { return }

        if step == .intent {
            store.complete(with: profile)
            // Not awaited: the person is one tap from breathing, and the upload
            // has a whole app lifetime to succeed in. `ProfileStore` has already
            // written the answers and closed onboarding by this point.
            Task { await store.syncIfNeeded() }
        }

        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
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

    /// The answers as they stand.
    public var profile: Profile {
        Profile(
            goals: goals,
            experienceLevel: experienceLevel,
            reminderIntensity: reminderIntensity,
            // Trimmed here as well as on the server, so what is stored locally
            // and what is stored remotely cannot differ by whitespace and leave
            // the sync flag flapping.
            intentNote: intentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
