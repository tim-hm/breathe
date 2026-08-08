import Foundation

/// Something this device keeps about the person, and the one thing deleting an
/// account asks of it.
///
/// The server half of a deletion is a single `DELETE` and the schema does the
/// rest. The device has no cascade: the practice is spread across a file of
/// sessions, a file of controlled pauses, half a dozen `UserDefaults` keys, the
/// in-memory copies every one of those is read into at launch, and a handful of
/// notification requests iOS is holding on this app's behalf. A deletion that
/// reached only the server would leave the whole journey on screen; one that
/// reached only the disk would leave it there until the next launch; and one
/// that stopped at this process would go on buzzing somebody's erased routine
/// onto their lock screen every weekday morning.
///
/// So each store answers for itself — it is the only thing that knows its own
/// file name, its own keys, and what it is holding in memory — and
/// `AccountModel` is handed the list rather than the knowledge.
public protocol PersonalStore: Sendable {
    /// Leaves this store exactly as a fresh install would find it.
    ///
    /// Both halves, always: whatever was written *and* whatever is cached in
    /// this process. That is the same rule `UserIdentityStore.adopt` follows and
    /// it is here for the same reason — a store that cleared its file and kept
    /// its `@Observable` copy goes on showing the erased person's practice for
    /// the life of the process, which is the version of this bug nobody notices
    /// in a test.
    func erase() async
}
