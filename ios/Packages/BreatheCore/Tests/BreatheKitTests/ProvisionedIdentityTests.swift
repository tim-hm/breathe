@testable import BreatheKit
import Foundation
import os
import Testing

/// The watch's half of the identity seam, driven through a fake store rather
/// than the Keychain — these run on the host, where the real one means an
/// unsigned process writing to a developer's login keychain.
///
/// The invariant under test is the one that would be expensive to discover in
/// the field: a watch that minted its own id would split a person's journey in
/// two, and nothing would look wrong until their streak stopped counting the
/// sessions they did on the wrist.
/// Counts both directions of traffic: "never mints" is a claim about what was
/// not written, and the caching is a claim about what was not read.
///
/// File scope rather than nested in the suite because its own state struct would
/// otherwise sit three types deep, and because `WatchHandoffInboxTests` provisions
/// through this too — the inbox's rules are about what reaches storage.
final class FakeStorage: IdentityStorage {
    private struct State {
        var id: UUID?
        var reads = 0
        var writes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(holding id: UUID? = nil) {
        state.withLock { $0.id = id }
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    var writes: Int {
        state.withLock { $0.writes }
    }

    func read() -> UUID? {
        state.withLock {
            $0.reads += 1
            return $0.id
        }
    }

    func replace(with id: UUID) -> Bool {
        state.withLock {
            $0.id = id
            $0.writes += 1
        }
        return true
    }
}

@Suite("Provisioned identity")
struct ProvisionedIdentityTests {
    @Test("An unprovisioned watch is anonymous and stays that way")
    func neverMintsAnIdentity() {
        let storage = FakeStorage()
        let store = ProvisionedUserIdentityStore(storage: storage)

        #expect(store.userId() == nil)
        #expect(store.userId() == nil, "a second read must not mint one either")
        #expect(storage.writes == 0)
    }

    /// A confirmed absence is cached like an id is. Every outbound RPC asks for
    /// the identity, so a watch that has never met its phone would otherwise pay
    /// a Keychain round-trip on each one, forever, to be told nothing again.
    @Test("An absent identity is looked up once, not on every request")
    func cachesTheConfirmedAbsence() {
        let storage = FakeStorage()
        let store = ProvisionedUserIdentityStore(storage: storage)

        _ = store.userId()
        _ = store.userId()

        #expect(storage.reads == 1)
    }

    @Test("The handed-over id is stored and answered from then on")
    func adoptsTheHandedOverId() {
        let store = ProvisionedUserIdentityStore(storage: FakeStorage())
        let id = UUID()

        #expect(store.provision(id))
        #expect(store.userId() == id)
    }

    /// The phone re-sends its context on every launch, and a watch that treated
    /// each one as news would kick a sync it has nothing to say in.
    @Test("Re-sending the same id changes nothing")
    func ignoresARepeatedHandover() {
        let id = UUID()
        let storage = FakeStorage(holding: id)
        let store = ProvisionedUserIdentityStore(storage: storage)

        #expect(store.provision(id) == false)
        #expect(storage.writes == 0)
    }

    /// Somebody who reinstalled the phone app arrives with a new id. The phone
    /// is the authority, so the watch follows rather than keeping an identity
    /// nothing else writes to.
    @Test("A different id replaces the stored one")
    func followsThePhoneToANewId() {
        let storage = FakeStorage(holding: UUID())
        let store = ProvisionedUserIdentityStore(storage: storage)
        let replacement = UUID()

        #expect(store.provision(replacement))
        #expect(store.userId() == replacement)
        #expect(storage.read() == replacement)
    }
}
