import Foundation
import Observation

/// Drives the one screen that puts somebody on a leaderboard, or takes them off
/// it.
///
/// In `OndKit` rather than the view for the reason `OnboardingModel` gives
/// about the intent note: the rule belongs to the answer, not to one way of
/// typing it, and the app target has no test bundle to pin it in. The rule here
/// is the same one, in the same unit — a name clamped by a count the server does
/// not share is a profile that fails every sync forever, silently.
@MainActor
@Observable
public final class LeaderboardNameModel {
    /// Clamped as it is typed, in the unit `String.clamped(toScalars:)`
    /// explains — the one the server's validation and the column `CHECK` both
    /// count.
    public var displayName: String {
        didSet {
            let clamped = displayName.clamped(toScalars: Profile.maxDisplayNameLength)
            if clamped != displayName {
                displayName = clamped
            }
        }
    }

    public var birthYearBand: BirthYearBand?

    /// True while the save is in flight, so the screen can refuse a second one.
    public private(set) var isSaving = false

    /// What the server said when it refused the answers, for the screen to show
    /// beside the field; `nil` when it did not refuse.
    ///
    /// A refusal is not a failed send. An unreachable server leaves the answer
    /// stored and retried, so showing it as saved is honest; a refused one never
    /// becomes true, and the same silence would leave somebody watching for a
    /// name that will never appear on a board.
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
        displayName = store.profile.displayName
        birthYearBand = store.profile.birthYearBand
    }

    /// Empty is always allowed — it means "take me off the boards", and clearing
    /// a name must stay as easy as setting one. Anything else has to clear the
    /// server's minimum, or the save would come back `INVALID_ARGUMENT`.
    public var canSave: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSaving
            && (trimmed.isEmpty || trimmed.unicodeScalars.count >= Profile.minDisplayNameLength)
    }

    /// Saves, and reflects back whatever the server decided to call this person.
    ///
    /// Awaited, unlike onboarding's: a taken name comes back suffixed, and
    /// somebody should see that here rather than discover it on a board later. A
    /// server that could not be reached is still not an error — the answer is
    /// stored locally and the next launch retries it.
    public func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        var profile = store.profile
        profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.birthYearBand = birthYearBand

        await store.save(profile)

        switch store.syncState {
        case .rejected:
            // The stored name is deliberately not read back here. It is the one
            // the server refused, and putting it in the field would present a
            // name nobody will ever see on a board as the one that was saved.
            break
        case .settled, .pending:
            displayName = store.profile.displayName
        }
    }
}
