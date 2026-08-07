import Foundation
import Observation

/// Which exercises' cautions this person has read and put away.
///
/// Keyed by slug and never global. The cautions are not one warning repeated —
/// box breathing's is about posture and the Wim Hof rounds' is about passing
/// out — so a single "don't show me these again" would silence a risk the person
/// has never met on the strength of one they have. Dismissing is therefore a
/// statement about one exercise and nothing else, and there is deliberately no
/// call here that clears them all.
///
/// Dismissal governs prominence, not availability: the browsing surfaces collapse
/// the card to a control that reopens the same words, and the session surfaces
/// never ask this store anything at all — a caution matters most while somebody
/// is breathing.
///
/// `UserDefaults` for the same reason `SessionSettings` uses it: this is a
/// preference about how the app presents itself, it belongs to the device, and
/// it has to survive a relaunch.
@MainActor
@Observable
public final class SafetyNoteStore {
    private static let dismissedKey = "safety.dismissedNotes"

    private var dismissedSlugs: Set<String> {
        didSet { defaults.set(dismissedSlugs.sorted(), forKey: Self.dismissedKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assigning in an initialiser does not run `didSet`, which is what keeps
        // this from writing back the value it just read.
        dismissedSlugs = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// Whether this person has put `technique`'s caution away.
    ///
    /// False for an exercise carrying no caution too, which costs the caller
    /// nothing: a note that does not exist is never shown either way.
    public func hasDismissed(_ technique: Technique) -> Bool {
        dismissedSlugs.contains(technique.slug)
    }

    /// Puts `technique`'s caution away, on this device, until the app is
    /// reinstalled. Idempotent.
    public func dismiss(_ technique: Technique) {
        // Guarded rather than assigned blindly: `didSet` writes to
        // `UserDefaults`, and a second dismissal of the same exercise should not
        // be a second write.
        guard !dismissedSlugs.contains(technique.slug) else { return }
        dismissedSlugs.insert(technique.slug)
    }
}
