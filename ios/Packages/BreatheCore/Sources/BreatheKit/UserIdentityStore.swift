import Foundation
import os
import Security

/// Where this install's anonymous identity is kept.
///
/// A protocol rather than a concrete type for two reasons: the watch app in M9
/// stores the id the phone sent it in its own Keychain and needs the same seam,
/// and nothing that depends on identity should have to reach the real Keychain
/// to be tested.
public protocol UserIdentityStore: Sendable {
    /// The id for this install, minting and storing one the first time it is
    /// asked for.
    ///
    /// `nil` only when the store itself is unreachable. Callers treat that as
    /// "anonymous for now" rather than as a failure: the catalogue is public, so
    /// an identity that cannot be read costs the profile sync and nothing else.
    func userId() -> UUID?
}

/// The Keychain-backed identity, and the only type here that touches Security.
///
/// `kSecClassGenericPassword` is chosen for what it survives rather than for
/// what it protects — there is no secret here, only a name. A Keychain item
/// outlives the app's container, so deleting and reinstalling the app returns
/// the same person to their own profile instead of stranding their history
/// behind an id nothing can reach.
///
/// The resolved id is remembered for the life of the process, because every
/// outbound RPC asks for it and a Keychain read is an XPC round-trip to
/// `securityd` — one on the wire path of every request is a cost with nothing to
/// show for it. Only a *successful* read fills the cache, so an identity minted
/// after this store was built is still picked up. Minting is made safe against a
/// race by treating a duplicate insert as a signal to re-read.
public final class KeychainUserIdentityStore: UserIdentityStore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
        category: "identity"
    )

    private let service: String
    private let account: String
    /// `OSAllocatedUnfairLock` rather than an actor: the caller is a synchronous
    /// interceptor on the request path, and an actor would make every RPC await
    /// a hop to read a value it already has.
    private let cached = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    /// - Parameters:
    ///   - service: the Keychain service the item is filed under. Defaults to
    ///     the running bundle so the phone app and M9's watch app, which are
    ///     separate bundles, do not collide before the id has been handed over.
    ///   - account: the item's account name. Fixed — there is one identity.
    public init(
        service: String = Bundle.main.bundleIdentifier ?? "xyz.holmie.breathe",
        account: String = "anonymous-user-id"
    ) {
        self.service = service
        self.account = account
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
        if let existing = read() {
            return existing
        }

        let minted = UUID()
        switch store(minted) {
        case errSecSuccess:
            return minted

        case errSecDuplicateItem:
            // Another caller minted one between the read and this write. Theirs
            // is the stored identity, and both callers must agree on it.
            return read()

        case let status:
            Self.logger.error("failed to store the anonymous identity: \(status)")
            return nil
        }
    }

    private func read() -> UUID? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            // Not finding one is the normal state on first launch, so only a
            // real failure is worth a line in the log.
            if status != errSecItemNotFound {
                Self.logger.error("failed to read the anonymous identity: \(status)")
            }
            return nil
        }

        guard let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: text)
        else {
            // Something else wrote this item, or it was truncated. Reporting it
            // rather than overwriting: an identity is not ours to discard, and a
            // fresh one would silently orphan whatever is stored against the old.
            Self.logger.error("the stored anonymous identity is not a UUID")
            return nil
        }

        return id
    }

    private func store(_ id: UUID) -> OSStatus {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = Data(id.uuidString.utf8)
        // Readable once the device has been unlocked at all, rather than only
        // while it is unlocked: M5 drains its sync queue in the background, and
        // a call that cannot read the identity cannot attribute what it sends.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
