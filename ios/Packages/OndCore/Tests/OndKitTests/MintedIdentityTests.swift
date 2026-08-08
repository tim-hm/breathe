import Foundation
@testable import OndKit
import os
import Testing

/// A Keychain that refuses every write, standing in for the only failure this
/// store has a deliberate answer to.
private struct RefusingStorage: IdentityStorage {
    let stored: UUID?

    func read() -> UUID? {
        stored
    }

    func insert(_: UUID) -> UUID? {
        nil
    }

    func replace(with _: UUID) -> Bool {
        false
    }
}

/// The phone's half of the identity seam: the store that mints, and the swap a
/// sign-in performs on it.
///
/// Driven through `IdentityStorage` rather than the Keychain, for the reason
/// `ProvisionedIdentityTests` gives — these run on the host, where the real one
/// means an unsigned process writing to a developer's login keychain.
///
/// Every failure here is silent in the field and permanent. An id that survives
/// a sign-in in the in-process cache is stamped onto requests naming a row the
/// server has already deleted, which `identity::resolve` recreates empty and
/// cannot tell from a first launch; a sign-out that keeps its id leaves the
/// install bound to the first Apple account with no server-side way back.
/// Neither shows up on a screen.
@Suite("Minted identity")
struct MintedIdentityTests {
    @Test("An id is minted once and remembered, not read on every request")
    func mintsOnceAndRemembers() throws {
        let storage = FakeStorage()
        let store = KeychainUserIdentityStore(storage: storage)

        let minted = try #require(store.userId())

        #expect(store.userId() == minted)
        #expect(storage.inserts == 1)
        #expect(storage.reads == 1, "the second ask must not reach storage at all")
    }

    /// The seam this issue exists for. `SignInWithApple` answers with an older
    /// identity whenever the Apple account already had one, and the caller's row
    /// is gone by the time it does — so a cache that kept answering with it
    /// would have every request until the next launch recreating that row empty
    /// and writing onto an orphan.
    @Test("Adopting replaces the cached id, not only the stored one")
    func adoptingInvalidatesTheCache() {
        let storage = FakeStorage(holding: UUID())
        let store = KeychainUserIdentityStore(storage: storage)
        let adopted = UUID()

        _ = store.userId()

        #expect(store.adopt(adopted))
        #expect(store.userId() == adopted)
        #expect(storage.read() == adopted)
    }

    /// A first sign-in — the Apple account had no identity of its own — is
    /// answered with the caller's own id. Nothing changed, so nothing else
    /// should be woken to hear about it.
    @Test("Adopting the id already held changes nothing")
    func ignoresAdoptingTheSameId() {
        let held = UUID()
        let storage = FakeStorage(holding: held)
        let store = KeychainUserIdentityStore(storage: storage)

        #expect(store.adopt(held) == false)
        #expect(storage.writes == 0)
    }

    /// Adopting is not a read, and must not mint on its way to a write: an id
    /// invented here would be one more row the server creates and nothing ever
    /// names again.
    @Test("Adopting into a store that has never resolved mints nothing")
    func adoptingNeverMints() {
        let storage = FakeStorage()
        let store = KeychainUserIdentityStore(storage: storage)
        let adopted = UUID()

        #expect(store.adopt(adopted))
        #expect(storage.inserts == 0)
        #expect(store.userId() == adopted)
    }

    /// The deliberate divergence from the watch's store, which keeps the
    /// identity it could store. By the time this is called the server has
    /// already merged, so the previous id names a row that no longer exists and
    /// going on sending it is the one outcome that loses history — worse than a
    /// swap this install forgets when it next launches.
    @Test("A swap the Keychain refused still takes effect in this process")
    func adoptsDespiteAFailedWrite() {
        let store = KeychainUserIdentityStore(storage: RefusingStorage(stored: UUID()))
        let adopted = UUID()

        #expect(store.adopt(adopted))
        #expect(store.userId() == adopted)
    }

    /// Signing out is `adopt` over a freshly minted id, and the thing that must
    /// not happen is a window with nothing stored: the interceptor asks for the
    /// identity on every request, and a resolve landing in that window would
    /// mint a third id that neither the person's history nor their Apple account
    /// has anything to do with.
    ///
    /// The reads race the swap rather than being sequenced against it, so this
    /// pins the invariant — every observation is one of the two ids, and storage
    /// is never minted into twice — rather than any particular interleaving.
    @Test("A request in flight across a swap sees one of the two ids and never a third")
    func swapsWithoutAWindowToMintInto() async throws {
        let storage = FakeStorage()
        let store = KeychainUserIdentityStore(storage: storage)
        let before = try #require(store.userId())
        let after = UUID()
        let observed = OSAllocatedUnfairLock<[UUID?]>(initialState: [])

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = store.adopt(after) }

            for _ in 0 ..< 64 {
                group.addTask {
                    let resolved = store.userId()
                    observed.withLock { $0.append(resolved) }
                }
            }
        }

        #expect(observed.withLock { $0 }.allSatisfy { $0 == before || $0 == after })
        #expect(store.userId() == after)
        #expect(storage.inserts == 1, "the swap left a window with no identity in it")
    }
}
