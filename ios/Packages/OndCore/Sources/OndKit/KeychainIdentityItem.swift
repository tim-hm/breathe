import Foundation
import os
import Security

/// The one Keychain item this app keeps, and the only place Security is called.
///
/// Extracted so the two identity stores above it — the phone's, which mints, and
/// the watch's, which is handed one — share a single description of where the id
/// lives and how it is written. Two copies of a `SecItemAdd` query is two places
/// for the service or the accessibility class to drift.
///
/// `kSecClassGenericPassword` is chosen for what it survives rather than for what
/// it protects: there is no secret here, only a name. A Keychain item outlives
/// the app's container, so deleting and reinstalling returns the same person to
/// their own history instead of stranding it behind an id nothing can reach.
struct KeychainIdentityItem: Sendable {
    private static let logger = Logger(category: "identity")

    let service: String
    let account: String

    func read() -> UUID? {
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

    /// Writes `id` where there is nothing stored, and answers with whatever the
    /// item holds afterwards.
    ///
    /// The `errSecDuplicateItem` branch is what makes minting safe against a
    /// race: another caller wrote between this one's read and this write, theirs
    /// is the stored identity, and both callers have to agree on it.
    ///
    /// - Returns: `id`, the value that beat it there, or nil where neither the
    ///   write nor the re-read could be made — which is the Keychain being
    ///   unreachable, and leaves this install anonymous for now rather than
    ///   inventing an identity it cannot store.
    func insert(_ id: UUID) -> UUID? {
        switch add(id) {
        case errSecSuccess:
            return id

        case errSecDuplicateItem:
            return read()

        case let status:
            Self.logger.error("failed to store the anonymous identity: \(status)")
            return nil
        }
    }

    /// Writes `id` only where there is nothing stored, reporting the raw status
    /// so a caller can tell a lost race (`errSecDuplicateItem`) from a failure.
    private func add(_ id: UUID) -> OSStatus {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = encode(id)
        // Readable once the device has been unlocked at all, rather than only
        // while it is unlocked: the sync queue drains in the background, and a
        // call that cannot read the identity cannot attribute what it sends.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Stores `id` whatever is already there — the handover path, where another
    /// device is the authority on who this is.
    ///
    /// - Returns: whether the item now holds `id`.
    func replace(with id: UUID) -> Bool {
        switch add(id) {
        case errSecSuccess:
            return true

        case errSecDuplicateItem:
            let status = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: encode(id)] as CFDictionary
            )
            if status != errSecSuccess {
                Self.logger.error("failed to replace the anonymous identity: \(status)")
            }
            return status == errSecSuccess

        case let status:
            Self.logger.error("failed to store the anonymous identity: \(status)")
            return false
        }
    }

    private func encode(_ id: UUID) -> Data {
        Data(id.uuidString.utf8)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
