import OndKit

/// The one identity store this app reads, shared rather than rebuilt.
///
/// `KeychainUserIdentityStore` remembers the id it resolved for the life of the
/// process, so a second instance is a second cache. That is harmless right up
/// until a sign-in merges this install into an older identity: the instance
/// nobody told goes on stamping the id the server has just deleted onto every
/// request it makes, the server recreates that row empty, and those writes land
/// on an orphan no Apple account points at.
///
/// File-scoped rather than threaded down from `OndApp` for the reason
/// `LiveAssistant` gives about itself: the assistant's repository is composed
/// away from the composition root, and reaching it with a parameter would mean a
/// required argument on every view between here and the coach.
enum LiveIdentity {
    static let store = KeychainUserIdentityStore()
}
