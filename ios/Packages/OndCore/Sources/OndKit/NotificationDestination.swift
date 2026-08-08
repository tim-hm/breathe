import Foundation

/// Where a tapped notification opens, once the slug it carries has been matched
/// against the catalogue and the tier the person is on.
///
/// Two answers and no third. There is deliberately no case for "that exercise is
/// gone": the catalogue is served rather than bundled, so a slug can outlive the
/// technique it names, and the honest response to one that resolves to nothing
/// is to open the app where it would have opened anyway — which is what `nil`
/// from the initialiser says.
public enum NotificationDestination: Sendable, Equatable {
    /// The exercise's session screen, held at rest until the person begins it.
    /// Being reminded is not the same as being ready.
    case session(Technique)

    /// The subscription offer, opened on the tier this exercise needs.
    ///
    /// Not the session screen, because a session screen that cannot start is the
    /// one place a reminder must never land. Not the exercise's own page either:
    /// somebody who scheduled this exercise has already read about it, and that
    /// page would only invite them to press Begin and be told the same thing.
    /// What they do not know is why it stopped opening, and the offer is both
    /// the answer and the only screen that can undo it. It is also where the
    /// catalogue sends a tap on a locked exercise, so the two agree.
    case offer(Technique)

    /// Resolves `payload` against the catalogue, or nil where the slug names
    /// nothing in it.
    public init?(
        _ payload: NotificationPayload,
        in techniques: [Technique],
        tier: SubscriptionTier
    ) {
        guard let technique = techniques.first(where: { $0.slug == payload.techniqueSlug })
        else { return nil }

        self = technique.isUnlocked(for: tier) ? .session(technique) : .offer(technique)
    }
}
