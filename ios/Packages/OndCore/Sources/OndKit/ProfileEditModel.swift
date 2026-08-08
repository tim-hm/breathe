import Foundation
import Observation

/// Drives a screen that changes what somebody already told the app about
/// themselves.
///
/// One model behind two screens — Settings' profile form, which shows every
/// answer, and the leaderboard's name sheet, which shows two of them. A model
/// each would put the display-name rule in two places, and that rule is the one
/// worth having in exactly one: a client that clamps by a different measure than
/// the server produces a profile whose every sync is rejected, forever, with
/// nothing on screen to say so.
///
/// In `OndKit` rather than the views for the reason `OnboardingModel` gives: the
/// rule belongs to the answer rather than to one way of typing it, and the app
/// target has no test bundle to pin it in.
@MainActor
@Observable
public final class ProfileEditModel {
    /// The answers as they stand on screen: the whole profile, taken from the
    /// store when this was made and written back by `save()`.
    ///
    /// One struct rather than a property per field, because `UpdateProfile` is
    /// a wholesale replacement — so a screen that binds two fields still sends
    /// seven, and the honest way to hold that is to edit the thing that gets
    /// sent. It also means a field added to `Profile` is editable through
    /// whichever screen binds it without this type growing a line.
    ///
    /// Snapshot semantics, which is safe because these screens live for seconds
    /// and nothing else writes the profile while one is up: the only other
    /// writer is the launch sync, and what it stores is what it was just sent.
    public var draft: Profile {
        didSet { clampToServerLimits() }
    }

    /// True while the save is in flight, so the screen can refuse a second one.
    public private(set) var isSaving = false

    /// What the server said when it refused the answers, for the screen to show;
    /// `nil` when it did not refuse.
    ///
    /// A refusal is not a failed send. An unreachable server leaves the answers
    /// stored and retried, so showing them as saved is honest; a refused one
    /// never becomes true, and the same silence would leave somebody watching
    /// for a name that will never appear on a board.
    ///
    /// Read from the store rather than copied out of it, so a refusal that
    /// arrives from anywhere else — a launch's `syncIfNeeded`, another screen —
    /// cannot leave this one showing a verdict that has since been replaced.
    public var rejection: String? {
        if case let .rejected(reason) = store.syncState {
            reason
        } else {
            nil
        }
    }

    private let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
        draft = store.profile
    }

    /// Adds or removes a goal, keeping the order they were picked in — the order
    /// the coach's prompt reads them back in, so it is an answer rather than a
    /// set.
    public func toggle(_ goal: TechniqueGoal) {
        if let index = draft.goals.firstIndex(of: goal) {
            draft.goals.remove(at: index)
        } else {
            draft.goals.append(goal)
        }
    }

    public func isSelected(_ goal: TechniqueGoal) -> Bool {
        draft.goals.contains(goal)
    }

    /// An empty name is always allowed — it means "take me off the boards", and
    /// clearing one must stay as easy as setting one. Anything else has to clear
    /// the server's minimum, or the save would come back `INVALID_ARGUMENT`.
    public var canSave: Bool {
        let trimmed = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSaving
            && (trimmed.isEmpty || trimmed.unicodeScalars.count >= Profile.minDisplayNameLength)
    }

    /// Saves, and reflects back whatever the server decided to store.
    ///
    /// Awaited, unlike onboarding's: a taken display name comes back suffixed
    /// and a duplicated goal comes back dropped, and somebody should see that
    /// here rather than discover it on a board later. A server that could not be
    /// reached is still not an error — the answers are stored locally and the
    /// next launch retries them.
    public func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.save(draft)

        switch store.syncState {
        case .rejected:
            // The stored answers are deliberately not read back. They are the
            // ones the server refused, and putting them on screen would present
            // a profile nobody else will ever see as the one that was saved.
            break
        case .settled, .pending:
            draft = store.profile
        }
    }

    /// Trims both free-text fields to what the server's validation and the
    /// column `CHECK` will accept, in the unit `String.clamped(toScalars:)`
    /// explains, so a field stops accepting input rather than letting somebody
    /// write past the point where saving would fail.
    ///
    /// Written through a local copy and assigned once, which is what keeps this
    /// finite: `draft` is observed, so trimming the two fields in place would
    /// re-enter here after the first of them — with the second still over its
    /// limit, so the guard would let every pass through and the recursion would
    /// not bottom out. One assignment re-enters exactly once, and that pass
    /// finds nothing left to trim.
    private func clampToServerLimits() {
        var clamped = draft
        clamped.displayName = draft.displayName.clamped(toScalars: Profile.maxDisplayNameLength)
        clamped.intentNote = draft.intentNote.clamped(toScalars: Profile.maxIntentNoteLength)
        guard clamped != draft else { return }

        draft = clamped
    }
}
