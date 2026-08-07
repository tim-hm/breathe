import BreatheKit
import Foundation
import Testing

@Suite("Keeping finished sessions until there is a server to send them to")
struct SessionStoreTests {
    /// A directory of this suite's own, so a run never reads what a previous one
    /// or the host's real app support directory left behind.
    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "breathe-session-store-\(UUID().uuidString)")
    }

    private func record(
        slug: String = "box-breathing",
        duration: Duration = .milliseconds(128_000),
        completed: Bool = true
    ) -> SessionRecord {
        SessionRecord(
            techniqueSlug: slug,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: duration,
            cyclesCompleted: 8,
            breathCount: 8,
            completed: completed
        )
    }

    /// The store is the only copy of a session until M5 syncs it, so every field
    /// it is trusted with has to survive the file — a dropped `id` would break
    /// the idempotency the sync retries on, and a dropped `completed` would turn
    /// an abandoned session into a finished one.
    @Test("A session survives the round trip through disk intact")
    func roundTripsASession() async {
        let directory = temporaryDirectory()
        let written = record(completed: false)

        await FileSessionStore(directory: directory).record(written)
        let read = await FileSessionStore(directory: directory).recordedSessions()

        #expect(read == [written])
        #expect(read.first?.duration == .milliseconds(128_000))
    }

    @Test("Sessions accumulate in the order they were finished")
    func appendsRatherThanReplaces() async {
        let store = FileSessionStore(directory: temporaryDirectory())

        await store.record(record(slug: "physiological-sigh"))
        await store.record(record(slug: "box-breathing"))
        await store.record(record(slug: "bellows-breath"))

        let slugs = await store.recordedSessions().map(\.techniqueSlug)
        #expect(slugs == ["physiological-sigh", "box-breathing", "bellows-breath"])
    }

    /// The first launch, and every launch until the first session ends.
    @Test("No history yet reads as no sessions, not as a failure")
    func startsEmpty() async {
        let sessions = await FileSessionStore(directory: temporaryDirectory()).recordedSessions()

        #expect(sessions.isEmpty)
    }

    /// Deletion has to hold against the sync: `merge` runs on every restore,
    /// and without the tombstone it would hand a deleted-but-synced session
    /// straight back on the next foreground.
    @Test("A deleted session stays deleted through a merge")
    func deletionSurvivesMerge() async {
        let store = FileSessionStore(directory: temporaryDirectory())
        let kept = record(slug: "box-breathing")
        let deleted = record(slug: "bellows-breath")

        await store.record(kept)
        await store.record(deleted)
        await store.remove(deleted.id)

        #expect(await store.recordedSessions() == [kept])

        // The server still holds both; only the one never deleted may return.
        let changed = await store.merge([kept, deleted])
        #expect(!changed)
        #expect(await store.recordedSessions() == [kept])
    }

    /// Removing an id the store never held must not tombstone it — the same id
    /// arriving later from the server is a session this device simply hadn't
    /// seen yet, not one the person got rid of.
    @Test("Removing an unknown id does not block it from a later merge")
    func unknownRemovalLeavesNoTombstone() async {
        let store = FileSessionStore(directory: temporaryDirectory())
        let incoming = record()

        await store.remove(incoming.id)
        let changed = await store.merge([incoming])

        #expect(changed)
        #expect(await store.recordedSessions() == [incoming])
    }

    /// Unreadable history must not take a session down with it: the person is
    /// mid-breath and there is nothing they could do about it.
    @Test("Corrupt history reads as empty rather than throwing")
    func survivesCorruptHistory() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "sessions.json"))

        let store = FileSessionStore(directory: directory)
        #expect(await store.recordedSessions().isEmpty)

        await store.record(record())
        #expect(await store.recordedSessions().count == 1)
    }
}
