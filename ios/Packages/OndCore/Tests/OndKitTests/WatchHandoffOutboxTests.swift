import Foundation
import OndKit
import os
import Testing

/// The phone's identity, without a Keychain behind it. Mutable, so a test can
/// be the person who signs in between two foregrounds and has their id replaced
/// by the one their Apple account already had.
private final class StubIdentity: UserIdentityStore {
    private let stored: OSAllocatedUnfairLock<UUID?>

    init(id: UUID?) {
        stored = OSAllocatedUnfairLock(initialState: id)
    }

    func userId() -> UUID? {
        stored.withLock { $0 }
    }

    @discardableResult
    func adopt(_ id: UUID) -> Bool {
        stored.withLock { current in
            guard current != id else { return false }
            current = id
            return true
        }
    }
}

/// Controlled-pause history, without a file behind it. Mutable so a test can be
/// the person who takes their first BOLT test between two foregrounds.
private final class StubScores: BoltScoreRecording {
    private let stored = OSAllocatedUnfairLock<[BoltScore]>(initialState: [])

    init(seconds: [Int] = []) {
        stored.withLock { $0 = seconds.map { BoltScore(seconds: $0) } }
    }

    func record(_ score: BoltScore) async {
        stored.withLock { $0.append(score) }
    }

    func recordedScores() async -> [BoltScore] {
        stored.withLock { $0 }
    }
}

/// A radio that never works, standing in for a phone whose watch has just been
/// unpaired or whose session refused the context.
private struct DeadRadio: Error {}

/// The phone's half of the handoff: what is worth sending, and what has already
/// been sent.
///
/// Worth pinning because both failure modes are silent. Sending an unchanged
/// context on every foreground wakes the watch to deliver news it already has;
/// recording one as delivered when it was not leaves a watch permanently one
/// context behind, with nothing on either screen to say so.
@MainActor
@Suite("Watch handoff outbox")
struct WatchHandoffOutboxTests {
    /// Collects what the outbox offers, standing in for `WCSession`.
    private final class Radio {
        private(set) var handed: [WatchHandoff] = []

        func accept(_ handoff: WatchHandoff) {
            handed.append(handoff)
        }
    }

    @Test("A phone with no identity yet has nothing to hand over")
    func waitsForAnIdentity() async {
        let radio = Radio()
        let outbox = WatchHandoffOutbox(
            identity: StubIdentity(id: nil),
            scores: StubScores(seconds: [30])
        )

        await outbox.handOver(radio.accept)

        #expect(radio.handed.isEmpty)
    }

    @Test("The first context carries the identity and the best pause")
    func handsOverTheFirstContext() async throws {
        let id = UUID()
        let radio = Radio()
        let outbox = WatchHandoffOutbox(
            identity: StubIdentity(id: id),
            scores: StubScores(seconds: [22, 41, 19])
        )

        await outbox.handOver(radio.accept)

        let handoff = try #require(radio.handed.first)
        #expect(handoff.userId == id)
        #expect(handoff.boltBestSeconds == 41, "the best of them, not the last")
    }

    /// The phone pushes on every foreground and almost none of them carry news.
    /// `updateApplicationContext` wakes the watch to deliver whatever it is
    /// given, so an unchanged context is radio time spent on nothing.
    @Test("An unchanged context is not handed over twice")
    func deduplicatesAnUnchangedContext() async {
        let radio = Radio()
        let outbox = WatchHandoffOutbox(
            identity: StubIdentity(id: UUID()),
            scores: StubScores(seconds: [30])
        )

        await outbox.handOver(radio.accept)
        await outbox.handOver(radio.accept)

        #expect(radio.handed.count == 1)
    }

    /// The other half of the same rule: a send that threw was never delivered, so
    /// the context has to still be outstanding when the next foreground asks.
    @Test("A hand-over that threw is offered again")
    func retriesAFailedHandover() async {
        let radio = Radio()
        let outbox = WatchHandoffOutbox(
            identity: StubIdentity(id: UUID()),
            scores: StubScores(seconds: [30])
        )

        try? await outbox.handOver { _ in throw DeadRadio() }
        await outbox.handOver(radio.accept)

        #expect(radio.handed.count == 1)
    }

    /// The reason the phone pushes at all after the first launch: a BOLT test
    /// taken on the phone has to reach the wrist, which cannot measure one.
    @Test("A new personal best is handed over")
    func handsOverANewBest() async {
        let radio = Radio()
        let scores = StubScores(seconds: [30])
        let outbox = WatchHandoffOutbox(identity: StubIdentity(id: UUID()), scores: scores)

        await outbox.handOver(radio.accept)
        await scores.record(BoltScore(seconds: 45))
        await outbox.handOver(radio.accept)

        #expect(radio.handed.map(\.boltBestSeconds) == [30, 45])
    }

    /// The wrist carries its own copy of the identity and caches it, so a
    /// sign-in that swapped the phone's leaves the watch syncing to a row the
    /// server has deleted — for as long as nothing tells it otherwise. What
    /// tells it is this context, which is only sent because the outbox compares
    /// what it holds rather than assuming an identity never changes.
    @Test("An identity replaced by a sign-in is handed over")
    func handsOverASwappedIdentity() async {
        let radio = Radio()
        let identity = StubIdentity(id: UUID())
        let outbox = WatchHandoffOutbox(identity: identity, scores: StubScores(seconds: [30]))

        await outbox.handOver(radio.accept)
        let adopted = UUID()
        identity.adopt(adopted)
        await outbox.handOver(radio.accept)

        #expect(radio.handed.count == 2)
        #expect(radio.handed.last?.userId == adopted)
    }

    /// The context that tells the wrist a person is gone, rather than merely
    /// filed under a different name.
    ///
    /// It has to survive a relaunch, which is why it is on disk: a watch can be
    /// off, out of range or unpaired for days after somebody deletes their
    /// account, and a marker that lived for the process would leave it holding
    /// their practice with nothing left to tell it otherwise.
    @Test("A deletion is handed over as an erasure, and goes on being one")
    func handsOverAnErasureUntilTheIdentityChangesAgain() async throws {
        let radio = Radio()
        let identity = StubIdentity(id: UUID())
        let defaults = try #require(
            UserDefaults(suiteName: "outbox-tests.erasure.\(UUID().uuidString)")
        )
        let outbox = WatchHandoffOutbox(
            identity: identity,
            scores: StubScores(),
            defaults: defaults
        )

        // What a deletion does, in the order `AccountModel` does it: mint, then
        // empty everything that holds anything.
        identity.adopt(UUID())
        await outbox.erase()
        await outbox.handOver(radio.accept)

        #expect(radio.handed.last?.erasesPriorHistory == true)

        // A fresh process, which is what a relaunch before the watch is next in
        // range amounts to.
        let relaunched = WatchHandoffOutbox(
            identity: identity,
            scores: StubScores(),
            defaults: defaults
        )
        await relaunched.handOver(radio.accept)

        #expect(radio.handed.last?.erasesPriorHistory == true)
    }

    /// The marker is stored as the identity it belongs to rather than as a flag,
    /// so it expires by itself: the next sign-in or sign-out mints another id
    /// and the contexts that follow are ordinary again, with nothing anywhere
    /// having to remember to clear it.
    @Test("An identity minted after the deletion is handed over as an ordinary one")
    func stopsErasingOnceTheIdentityMovesOn() async throws {
        let radio = Radio()
        let identity = StubIdentity(id: UUID())
        let defaults = try #require(
            UserDefaults(suiteName: "outbox-tests.expiry.\(UUID().uuidString)")
        )
        let outbox = WatchHandoffOutbox(
            identity: identity,
            scores: StubScores(),
            defaults: defaults
        )

        identity.adopt(UUID())
        await outbox.erase()
        await outbox.handOver(radio.accept)

        identity.adopt(UUID())
        await outbox.handOver(radio.accept)

        #expect(radio.handed.map(\.erasesPriorHistory) == [true, false])
    }

    /// A worse score is not news. The watch mirrors the best, so a later, shorter
    /// pause leaves the context exactly as it was.
    @Test("A worse score is not news")
    func ignoresAWorseScore() async {
        let radio = Radio()
        let scores = StubScores(seconds: [45])
        let outbox = WatchHandoffOutbox(identity: StubIdentity(id: UUID()), scores: scores)

        await outbox.handOver(radio.accept)
        await scores.record(BoltScore(seconds: 12))
        await outbox.handOver(radio.accept)

        #expect(radio.handed.count == 1)
    }
}
