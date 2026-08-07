@testable import BreatheKit
import Foundation
import Testing

/// What the spy below remembers. At file scope only because the lint rule
/// caps type nesting one level short of where this naturally lives.
private enum HealthCall: Equatable {
    case requestedRead
    case requestedWrite
    case wroteMindfulSession(start: Date, end: Date)
}

/// The write-back's two promises: every session a screen records is credited
/// to Health over exactly the span it was breathed, and nothing else — not a
/// restore, not a removal — ever writes there.
@Suite("Mindful Minutes write-back")
struct MindfulMinutesRecorderTests {
    /// Remembers every call in order, so a test can assert that authorization
    /// was asked before the write — and that nothing was asked at all.
    private actor SpyHealthStore: HealthStore {
        private(set) var calls: [HealthCall] = []

        func requestReadAuthorization() async {
            calls.append(.requestedRead)
        }

        func requestWriteAuthorization() async {
            calls.append(.requestedWrite)
        }

        func restingHeartRate(from _: Date, to _: Date) async -> [DailyQuantity] {
            []
        }

        func heartRateVariability(from _: Date, to _: Date) async -> [DailyQuantity] {
            []
        }

        func writeMindfulSession(from start: Date, to end: Date) async {
            calls.append(.wroteMindfulSession(start: start, end: end))
        }
    }

    /// Remembers what it was asked to keep, so the tests can prove the wrapped
    /// store still sees everything the wrapper does.
    private actor CountingRecorder: SessionRecording {
        private(set) var kept: [SessionRecord] = []
        private(set) var removed: [SessionRecord.ID] = []

        func record(_ session: SessionRecord) async {
            kept.append(session)
        }

        func recordedSessions() async -> [SessionRecord] {
            kept
        }

        func remove(_ id: SessionRecord.ID) async {
            removed.append(id)
        }

        func merge(_ sessions: [SessionRecord]) async -> Bool {
            kept.append(contentsOf: sessions)
            return !sessions.isEmpty
        }
    }

    private static let startedAt = Date(timeIntervalSince1970: 1_777_000_000)

    // Fresh per test: Swift Testing builds a new suite value for each one.
    private let store = CountingRecorder()
    private let health = SpyHealthStore()
    private let recorder: MindfulMinutesRecorder

    init() {
        recorder = MindfulMinutesRecorder(wrapping: store, health: health)
    }

    private func session(minutes: Int = 5) -> SessionRecord {
        SessionRecord(
            techniqueSlug: "box-breathing",
            startedAt: Self.startedAt,
            duration: .seconds(minutes * 60),
            cyclesCompleted: 10,
            breathCount: 10,
            completed: true
        )
    }

    @Test("A recorded session asks for write access, then credits its span")
    func recordWritesToHealth() async {
        let session = session(minutes: 5)
        await recorder.record(session)

        #expect(await store.kept == [session])
        #expect(await health.calls == [
            .requestedWrite,
            .wroteMindfulSession(
                start: Self.startedAt,
                end: Self.startedAt.addingTimeInterval(5 * 60)
            ),
        ])
    }

    @Test("Restored history is not new practice — a merge writes nothing")
    func mergeStaysOutOfHealth() async {
        let added = await recorder.merge([session()])

        #expect(added)
        #expect(await store.kept.count == 1)
        #expect(await health.calls.isEmpty)
    }

    @Test("Reads and removals pass straight through, touching Health never")
    func forwarding() async {
        let session = session()
        await store.record(session)

        #expect(await recorder.recordedSessions() == [session])
        await recorder.remove(session.id)
        #expect(await store.removed == [session.id])
        #expect(await health.calls.isEmpty)
    }
}
