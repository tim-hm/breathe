import Foundation

/// What a notification carries besides its words: which exercise it is for.
///
/// Attached when the notification is scheduled and read back when it is tapped,
/// so the notification describes itself. The alternative — recovering the
/// schedule from the request identifier, which does encode it — makes the
/// notification a pointer into state that is free to move. Days pass between
/// placing a reminder and it firing, and in that gap the schedule behind it can
/// be pointed at a different exercise or deleted outright; a payload has nothing
/// behind it to go stale.
///
/// A slug rather than the schedule's id for the same reason, and for one more: a
/// push sent by the server has no schedule of anybody's to name, and it should
/// arrive on this road rather than a second one.
public struct NotificationPayload: Sendable, Equatable {
    /// The key the slug travels under, in both directions.
    ///
    /// Private, because one spelling on the sending side and another on the
    /// receiving side is a bug that only appears on a device, days later, when a
    /// reminder finally fires.
    private static let techniqueSlugKey = "techniqueSlug"

    /// The exercise to open, by the slug the catalogue keeps stable.
    public let techniqueSlug: String

    public init(techniqueSlug: String) {
        self.techniqueSlug = techniqueSlug
    }

    /// What to hand `UNMutableNotificationContent.userInfo`.
    ///
    /// Strings only. This dictionary is serialised — to disk by the notification
    /// centre, and over the wire by APNs — so anything richer than a
    /// property-list scalar is a decode waiting to fail somewhere with nobody to
    /// report it to.
    public var userInfo: [String: String] {
        [Self.techniqueSlugKey: techniqueSlug]
    }

    /// Reads a payload back off a tapped notification, or nil where there is
    /// none: a reminder placed by a build from before this shipped, or a
    /// notification that was never about an exercise.
    ///
    /// Takes iOS's own `[AnyHashable: Any]` rather than something tidier so the
    /// one unavoidable cast in the round trip lives here, where a host test can
    /// reach it, instead of in the delegate, where nothing can.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let slug = userInfo[Self.techniqueSlugKey] as? String, !slug.isEmpty else {
            return nil
        }
        techniqueSlug = slug
    }
}
