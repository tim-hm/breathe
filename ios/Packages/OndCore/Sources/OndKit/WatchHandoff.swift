import Foundation

/// What the phone tells the wrist about the person using it.
///
/// Carried in WatchConnectivity's `applicationContext`, which is a last-value-
/// wins dictionary the system delivers whenever the watch next runs — exactly
/// the semantics this payload wants, since none of it is an event and a missed
/// update is superseded rather than lost.
///
/// It lives in `OndKit` because both apps have to agree on the key names
/// down to the character, and an agreement written twice is one that drifts. The
/// dictionary is `[String: Any]` because that is what `WCSession` takes; the
/// conversion is confined here so no view or delegate elsewhere handles untyped
/// values.
public struct WatchHandoff: Sendable, Equatable {
    /// The anonymous id both devices attribute their sessions to. The watch
    /// never invents one, so this is the only way it ever gets an identity.
    public let userId: UUID
    /// The best controlled pause the phone has recorded, or nil before the
    /// first test. Mirrored rather than folded on the watch: the BOLT test is a
    /// phone screen — a stopwatch you hold your breath against — so the wrist
    /// reports the number and never measures it.
    ///
    /// Never zero. Nobody held their breath for no seconds, and a value free to
    /// arrive as either `nil` or `0` would make two handoffs that mean the same
    /// thing compare unequal.
    public let boltBestSeconds: Int?

    /// Normalises the score here, in the one initialiser everything else routes
    /// through, so neither the encoder nor the decoder has to remember to.
    public init(userId: UUID, boltBestSeconds: Int? = nil) {
        self.userId = userId
        self.boltBestSeconds = boltBestSeconds.flatMap { $0 > 0 ? $0 : nil }
    }

    private static let userIdKey = "userId"
    private static let boltBestKey = "boltBestSeconds"

    public var dictionary: [String: Any] {
        var context: [String: Any] = [Self.userIdKey: userId.uuidString]
        // Absent rather than zero: the key means "there is a best", and the
        // initialiser has already ruled out a zero reaching here.
        if let boltBestSeconds {
            context[Self.boltBestKey] = boltBestSeconds
        }
        return context
    }

    /// Reads a context the phone sent, or nil where it carries no usable id.
    ///
    /// Total and non-throwing: this runs on WatchConnectivity's delivery queue
    /// with whatever the system hands over, including the empty dictionary a
    /// never-configured session reports, and there is nothing a watch app could
    /// do about a malformed one but ignore it.
    public init?(dictionary: [String: Any]) {
        guard let raw = dictionary[Self.userIdKey] as? String,
              let userId = UUID(uuidString: raw)
        else {
            return nil
        }

        self.init(userId: userId, boltBestSeconds: dictionary[Self.boltBestKey] as? Int)
    }
}
