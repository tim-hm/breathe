import Foundation

/// One session a person actually did.
///
/// Recorded locally from the first session onwards, before there is any account
/// to attach it to. The field set is deliberately the one the future
/// `RecordSessions` RPC takes — including `id`, which is the idempotency key a
/// sync can retry against — so syncing later is a mapping rather than a
/// migration of everything already on disk.
public struct SessionRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let techniqueSlug: String
    public let startedAt: Date
    /// Milliseconds rather than a `Duration`, because this shape is written to
    /// disk: milliseconds are what the proto carries and what a person reading
    /// the file can understand, where an encoded `Duration` is a pair of opaque
    /// integers.
    public let durationMs: Int
    /// Cycles wholly finished. A session ended mid-cycle counts the cycles
    /// behind it, never the one it was in.
    public let cyclesCompleted: Int
    /// Inhales taken — two per cycle in techniques like the physiological sigh.
    public let breathCount: Int
    /// Whether the timeline ran out, as opposed to the person ending it early.
    /// Both are recorded; only this distinguishes them.
    public let completed: Bool

    public init(
        id: UUID = UUID(),
        techniqueSlug: String,
        startedAt: Date,
        duration: Duration,
        cyclesCompleted: Int,
        breathCount: Int,
        completed: Bool
    ) {
        self.id = id
        self.techniqueSlug = techniqueSlug
        self.startedAt = startedAt
        durationMs = Int(duration.milliseconds)
        self.cyclesCompleted = cyclesCompleted
        self.breathCount = breathCount
        self.completed = completed
    }

    public var duration: Duration {
        .milliseconds(durationMs)
    }

    /// What a summary leads with.
    ///
    /// Here rather than in either summary screen because the product's copy
    /// rule is a rule: celebrate what happened, never grade it. Two views of
    /// the same session — one in the hand, one on the wrist — saying different
    /// things about it is exactly the drift that turns a rule into a habit
    /// somebody remembered.
    public var headline: String {
        if completed {
            "Nicely done."
        } else if cyclesCompleted > 0 {
            "Every cycle counts."
        } else {
            "Every breath counts."
        }
    }

    /// "cycle" or "cycles", for the count beside it.
    public var cyclesLabel: String {
        cyclesCompleted == 1 ? "cycle" : "cycles"
    }

    /// "breath" or "breaths", for the count beside it.
    public var breathsLabel: String {
        breathCount == 1 ? "breath" : "breaths"
    }
}

/// Somewhere to keep finished sessions until there is a server to send them to.
///
/// Non-throwing on purpose: a failed local write is nothing the person mid-way
/// through a breathing session can act on, and nothing a caller can retry
/// meaningfully. Implementations log and carry on.
public protocol SessionRecording: Sendable {
    func record(_ session: SessionRecord) async
    /// Every recorded session, oldest first.
    func recordedSessions() async -> [SessionRecord]
    /// Adds sessions this device does not hold, matching on `id`. The restore
    /// path: the identity survives a reinstall, so the server can hold history
    /// this file has lost.
    ///
    /// - Returns: whether anything new was added. The answer to "did local
    ///   state change", which is what decides whether a screen re-reads it —
    ///   the server holding sessions it already sent us is the common case,
    ///   and it changes nothing.
    func merge(_ sessions: [SessionRecord]) async -> Bool
}
