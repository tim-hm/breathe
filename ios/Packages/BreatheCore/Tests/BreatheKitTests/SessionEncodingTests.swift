import BreatheAPI
@testable import BreatheKit
import Foundation
import Testing

/// Putting a locally recorded session on the wire.
///
/// The numbers come back from `sessions.json`, which `SessionRecord`'s own doc
/// promises a person can read and `JSONFileStore.load()` range-checks not at
/// all — and every counter on the wire is unsigned 32-bit. The sync that encodes
/// them runs on every foreground, so a trapping conversion here is a crash loop
/// with no way out short of deleting the app.
///
/// The counters are decoded from JSON through the same `.iso8601` decoder the
/// store uses, because the file is where the bad value comes from and a decoder
/// configured differently would be testing a boundary the app does not have.
@Suite("Encoding a session for the wire")
struct SessionEncodingTests {
    private func record(
        durationMs: String = "240000",
        cyclesCompleted: String = "4",
        breathCount: String = "8"
    ) throws -> SessionRecord {
        let json = """
        {
          "id": "8A7B0F6E-4C1D-4E2A-9B3F-0D5C6E7A8B90",
          "techniqueSlug": "box-breathing",
          "startedAt": "2026-08-07T09:15:00Z",
          "durationMs": \(durationMs),
          "cyclesCompleted": \(cyclesCompleted),
          "breathCount": \(breathCount),
          "completed": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionRecord.self, from: Data(json.utf8))
    }

    /// Each counter is asserted against its own field, because the guards are
    /// what stand between the three of them and a swap the compiler cannot see.
    @Test("A session as the app writes it survives the encode")
    func encodesAWellFormedSession() throws {
        let message = try record().proto

        #expect(message.durationMs == 240_000)
        #expect(message.cyclesCompleted == 4)
        #expect(message.breathCount == 8)
    }

    /// A clamp would be worse than a refusal on either end: it reports a session
    /// nobody did, and a person's own figures are the ones they are most likely
    /// to believe.
    @Test("A count outside the wire's range is refused, not clamped and not trapped")
    func refusesAnOutOfRangeCount() throws {
        let tooLarge = try record(cyclesCompleted: "99999999999")
        let negative = try record(durationMs: "-1")

        #expect(throws: JourneyRepositoryError.self) { _ = try tooLarge.proto }
        #expect(throws: JourneyRepositoryError.self) { _ = try negative.proto }
    }

    /// Built rather than decoded, unlike the counters: ISO-8601 cannot express
    /// an instant this far out, so the file is not the way one arrives. A `Date`
    /// is a `Double`, though, and any arithmetic that produces one reaches the
    /// same `Int64` conversion — which used to trap.
    @Test("An instant the wire cannot carry is refused too")
    func refusesAnUnrepresentableInstant() {
        let absurd = SessionRecord(
            techniqueSlug: "box-breathing",
            startedAt: Date(timeIntervalSince1970: 1e30),
            duration: .seconds(240),
            cyclesCompleted: 4,
            breathCount: 8,
            completed: true
        )

        #expect(throws: JourneyRepositoryError.self) { _ = try absurd.proto }
    }
}
