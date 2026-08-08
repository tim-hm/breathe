import Foundation
import os

/// The identity on a device that is given one rather than making one up: the
/// watch, which receives the phone's anonymous id over WatchConnectivity.
///
/// It **never** mints. That is the whole reason this type exists beside
/// `KeychainUserIdentityStore`: two ids for one person would split their journey
/// in half, with sessions from the wrist accumulating against a stranger the
/// phone can never see. Until the phone has been in range once, `userId()`
/// answers nil — the catalogue is public and sessions record locally, so the
/// watch is fully usable meanwhile and the sync queue simply waits.
public final class ProvisionedUserIdentityStore: UserIdentityStore {
    private static let logger = Logger(category: "identity")

    /// What the store has been found to hold. Three states rather than an
    /// optional, because "nobody has looked yet" and "there is nothing there"
    /// are different answers and only one of them is worth re-asking.
    private enum Resolution: Sendable {
        case unread
        /// Confirmed empty. Cached like an id, and safe to: `provision` is the
        /// only writer in this process and updates this on its way past, so
        /// there is nothing a second read could discover. A watch that never
        /// meets its phone would otherwise pay a Keychain round-trip on every
        /// RPC it ever makes, forever.
        case absent
        case present(UUID)
    }

    private let storage: any IdentityStorage
    /// Same reasoning as the minting store's: the reader is a synchronous
    /// interceptor on every request's path, so it must not hop or block.
    private let cached = OSAllocatedUnfairLock<Resolution>(initialState: .unread)

    /// - Parameters:
    ///   - service: the Keychain service the item is filed under. Defaults to
    ///     the running bundle, which on the watch is its own — the id it holds
    ///     is a copy of the phone's, not a shared item.
    ///   - account: the item's account name, matching the phone's so that the
    ///     two devices file the same thing under the same name.
    public convenience init(
        service: String = Bundle.main.bundleIdentifier ?? "xyz.holmie.ond.watchkitapp",
        account: String = "anonymous-user-id"
    ) {
        self.init(storage: KeychainIdentityItem(service: service, account: account))
    }

    init(storage: any IdentityStorage) {
        self.storage = storage
    }

    public func userId() -> UUID? {
        switch cached.withLock({ $0 }) {
        case .unread: break
        case .absent: return nil
        case let .present(id): return id
        }

        guard let stored = storage.read() else {
            cached.withLock { $0 = .absent }
            return nil
        }

        cached.withLock { $0 = .present(stored) }
        return stored
    }

    /// Adopts the id the phone sent.
    ///
    /// An id that differs from the stored one replaces it, because the phone is
    /// the authority on who this person is — someone who reinstalled the phone
    /// app, or signed in and had their anonymous identity merged into an older
    /// one, arrives with a new id, and a watch that kept the old one would go on
    /// syncing to an identity nothing else writes to. Sessions already on the
    /// wrist and not yet acknowledged go up under the new id, which is where the
    /// person's history now lives.
    ///
    /// A failed write leaves the identity alone, which is where this parts
    /// company with the minting store: the phone re-sends its context on every
    /// foreground, so a wrist that missed one is told again shortly, and staying
    /// on the last id it could actually store is better than answering with one
    /// the next launch will not remember.
    ///
    /// - Returns: whether this changed the stored identity — the signal to kick
    ///   a sync, and nothing to do on the every-launch case where the phone
    ///   re-sends the id the watch already holds.
    @discardableResult
    public func adopt(_ id: UUID) -> Bool {
        guard userId() != id else { return false }

        guard storage.replace(with: id) else {
            Self.logger.error("the handed-over identity could not be stored")
            return false
        }

        cached.withLock { $0 = .present(id) }
        return true
    }
}
