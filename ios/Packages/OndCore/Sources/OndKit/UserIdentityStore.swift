import Foundation
import os

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

    /// Makes `id` the identity from now on, replacing whatever was held.
    ///
    /// Both devices are told who they are by somebody else at some point: the
    /// watch by the phone, and the phone by `AccountService.SignInWithApple`,
    /// which answers with an *older* identity whenever the Apple account already
    /// had one and merges the caller into it. Nothing on the server defends the
    /// id left behind — `identity::resolve` upserts a row for any well-formed id
    /// and cannot tell a merged-away one from a first launch — so a single later
    /// request carrying it recreates that row empty and the write lands on an
    /// orphan no Apple account points at.
    ///
    /// Which is why this replaces the cache and not only the store. Every
    /// implementation here remembers what it resolved for the life of the
    /// process, and a swap that reached the Keychain alone would leave every
    /// request until the next launch stamped with the id that no longer exists.
    ///
    /// - Returns: whether this changed the identity being answered with — the
    ///   signal to tell everything else holding a copy. False is the ordinary
    ///   no-op: the phone re-sending the id the watch already holds, or a first
    ///   sign-in where the server hands back the caller's own id.
    @discardableResult
    func adopt(_ id: UUID) -> Bool
}

/// Somewhere an identity is written and read back.
///
/// A seam rather than the Keychain directly, so the rules above it can be pinned
/// by tests that run on the host — where reaching the real Keychain means an
/// unsigned process writing to a developer's login keychain. Both stores need
/// it: the watch's, whose rule is that it never mints, and the phone's, whose
/// rules are that a swap is atomic and that signing out leaves no id behind.
protocol IdentityStorage: Sendable {
    func read() -> UUID?

    /// Stores `id` only where there is nothing stored.
    ///
    /// - Returns: what the store holds afterwards — `id`, or the value a writer
    ///   that got there first put in it, or nil where the write failed.
    func insert(_ id: UUID) -> UUID?

    /// - Returns: whether the store now holds `id`.
    func replace(with id: UUID) -> Bool
}

extension KeychainIdentityItem: IdentityStorage {}

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
/// race by treating a duplicate insert as a signal to re-read, which is
/// `KeychainIdentityItem.insert`'s job.
///
/// One instance per process, please. A second one is a second cache, and after
/// a sign-in has swapped the identity underneath it, the instance nobody told
/// goes on stamping the merged-away id onto every request it makes.
public final class KeychainUserIdentityStore: UserIdentityStore {
    private static let logger = Logger(category: "identity")

    private let storage: any IdentityStorage
    /// `OSAllocatedUnfairLock` rather than an actor: the caller is a synchronous
    /// interceptor on the request path, and an actor would make every RPC await
    /// a hop to read a value it already has.
    ///
    /// Held across the storage call in both members below, which is deliberate
    /// and is the whole of what makes a swap atomic. Released around the read, a
    /// request could resolve the old id, wait out an adopt, and then cache the
    /// identity the server has just deleted over the one that replaced it —
    /// silently, and for the life of the process.
    ///
    /// It costs nothing on the path the cache exists for. A resolved identity is
    /// still one uncontended acquire and a read, with no XPC anywhere near it;
    /// what now happens under the lock is the *unresolved* case, once per
    /// process, where concurrent first callers queue behind a single Keychain
    /// round-trip instead of each making their own.
    private let cached = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    /// - Parameters:
    ///   - service: the Keychain service the item is filed under. Defaults to
    ///     the running bundle so the phone app and the watch app, which are
    ///     separate bundles, do not collide before the id has been handed over.
    ///   - account: the item's account name. Fixed — there is one identity.
    public convenience init(
        service: String = Bundle.main.bundleIdentifier ?? "xyz.holmie.ond",
        account: String = "anonymous-user-id"
    ) {
        self.init(storage: KeychainIdentityItem(service: service, account: account))
    }

    init(storage: any IdentityStorage) {
        self.storage = storage
    }

    public func userId() -> UUID? {
        cached.withLock { remembered in
            if let remembered {
                return remembered
            }

            remembered = storage.read() ?? storage.insert(UUID())
            return remembered
        }
    }

    /// Adopts the id `AccountService.SignInWithApple` answered with, or the
    /// fresh one a sign-out mints.
    ///
    /// The cache is written whether or not the Keychain took the value, which is
    /// where this parts company with the watch's store. By the time this is
    /// called the server has already merged and the previous id names a row that
    /// no longer exists, so continuing to send it is the one outcome that loses
    /// history — worse than a swap this install forgets at the next launch. A
    /// failed write is therefore an error line and not a refusal.
    ///
    /// One acquisition of the lock, deciding included. Reading the identity
    /// through `userId()` first would release the lock before taking it again to
    /// write, and what fits in that gap is a request resolving the old id — or
    /// a second sign-in deciding against the same stale answer. Nothing here
    /// mints, either, which is the other reason not to route through
    /// `userId()`: adopting into an empty store would otherwise write an id
    /// solely to overwrite it.
    @discardableResult
    public func adopt(_ id: UUID) -> Bool {
        cached.withLock { remembered in
            let current = remembered ?? storage.read()
            guard current != id else {
                remembered = current
                return false
            }

            remembered = id

            if !storage.replace(with: id) {
                Self.logger.error("the adopted identity could not be stored")
            }

            return true
        }
    }
}
