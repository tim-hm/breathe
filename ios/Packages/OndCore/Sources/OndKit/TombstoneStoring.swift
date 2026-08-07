import Foundation

/// The ids of sessions this device deleted and the server may still hold.
///
/// Separate from `SessionRecording` rather than a fifth requirement on it: a
/// tombstone is not session history, and only the sync queue has any business
/// reading one. Everything else that records or reads sessions — the session
/// model, the watch, the journey screen — would be conforming to a pair of
/// methods it can never call.
///
/// The contract is one-way and deliberately conservative: a tombstone is only
/// dropped once the server has confirmed it has forgotten the session, so a
/// failed request costs a repeated delete rather than a resurrected session.
public protocol TombstoneStoring: Sendable {
    /// Ids deleted here that the server has not yet been told about.
    func tombstonedSessions() async -> [SessionRecord.ID]

    /// Drops the ids the server has confirmed it no longer holds.
    ///
    /// Called only after a successful `DeleteSessions`, and with exactly the
    /// ids that call carried — a wider drop would forget a deletion that never
    /// reached the server, and the next restore would hand the session back.
    func forgetTombstones(_ ids: [SessionRecord.ID]) async
}
