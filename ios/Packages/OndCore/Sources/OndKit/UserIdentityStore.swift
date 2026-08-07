import Foundation
import os
import Security

/// Where this install's anonymous identity is kept.
///
/// A protocol rather than a concrete type for two reasons: the watch app stores
/// the id the phone sent it rather than minting one and needs the same seam, and
/// nothing that depends on identity should have to reach the real Keychain to be
/// tested.
public protocol UserIdentityStore: Sendable {
    /// The id this install attributes its work to, or nil while it has none.
    ///
    /// Where an id *comes from* is the implementation's business and differs by
    /// device: the phone mints one on first use, the watch waits to be handed
    /// the phone's. Callers treat nil as "anonymous for now" rather than as a
    /// failure — the catalogue is public, so an absent identity costs the
    /// scoped RPCs and nothing else.
    func userId() -> UUID?
}

/// The minting identity: the phone, where an id comes into existence.
///
/// `userId()` mints and stores one the first time it is asked, so this store
/// answers nil only when the Keychain itself is unreachable.
///
/// The resolved id is remembered for the life of the process, because every
/// outbound RPC asks for it and a Keychain read is an XPC round-trip to
/// `securityd` — one on the wire path of every request is a cost with nothing to
/// show for it. Only a *successful* read fills the cache, so an identity minted
/// after this store was built is still picked up. Minting is made safe against a
/// race by treating a duplicate insert as a signal to re-read.
public final class KeychainUserIdentityStore: UserIdentityStore {
    private static let logger = Logger(category: "identity")

    private let item: KeychainIdentityItem
    /// `OSAllocatedUnfairLock` rather than an actor: the caller is a synchronous
    /// interceptor on the request path, and an actor would make every RPC await
    /// a hop to read a value it already has.
    private let cached = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    /// - Parameters:
    ///   - service: the Keychain service the item is filed under. Defaults to
    ///     the running bundle so the phone app and the watch app, which are
    ///     separate bundles, do not collide before the id has been handed over.
    ///   - account: the item's account name. Fixed — there is one identity.
    public init(
        service: String = Bundle.main.bundleIdentifier ?? "xyz.holmie.breathe",
        account: String = "anonymous-user-id"
    ) {
        item = KeychainIdentityItem(service: service, account: account)
    }

    public func userId() -> UUID? {
        if let remembered = cached.withLock({ $0 }) {
            return remembered
        }

        guard let resolved = resolve() else { return nil }
        cached.withLock { $0 = resolved }
        return resolved
    }

    /// The stored id, minting and writing one if there is none.
    private func resolve() -> UUID? {
        if let existing = item.read() {
            return existing
        }

        let minted = UUID()
        switch item.add(minted) {
        case errSecSuccess:
            return minted

        case errSecDuplicateItem:
            // Another caller minted one between the read and this write. Theirs
            // is the stored identity, and both callers must agree on it.
            return item.read()

        case let status:
            Self.logger.error("failed to store the anonymous identity: \(status)")
            return nil
        }
    }
}
