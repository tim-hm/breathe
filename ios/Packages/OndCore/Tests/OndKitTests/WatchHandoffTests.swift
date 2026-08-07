import Foundation
import OndKit
import Testing

/// The phone-to-watch context, driven through the dictionary WatchConnectivity
/// actually carries.
///
/// Worth pinning because both apps encode it independently and the compiler
/// checks neither: a renamed key is invisible until a watch in someone's hand
/// silently never receives an identity.
@Suite("Watch handoff")
struct WatchHandoffTests {
    @Test("The context round-trips both fields")
    func roundTripsEverything() throws {
        let sent = WatchHandoff(userId: UUID(), boltBestSeconds: 42)

        let received = try #require(WatchHandoff(dictionary: sent.dictionary))

        #expect(received == sent)
    }

    /// The common case for a long time: somebody breathing on the wrist who has
    /// never taken a controlled-pause test.
    @Test("A handoff with no BOLT score round-trips as no score")
    func roundTripsWithoutAScore() throws {
        let sent = WatchHandoff(userId: UUID())

        let context = sent.dictionary
        let received = try #require(WatchHandoff(dictionary: context))

        #expect(received.boltBestSeconds == nil)
        #expect(context.count == 1, "an absent score should not travel as a key at all")
    }

    /// A zero is what a phone with an empty score file would send if anything
    /// ever summed rather than maxed. Nobody held their breath for no seconds,
    /// so it must not surface as a personal best on the wrist — whichever side
    /// of the wire the zero came in on.
    @Test("A zero-second best is no best, however it arrives")
    func rejectsAZeroScore() throws {
        let id = UUID()
        let context: [String: Any] = ["userId": id.uuidString, "boltBestSeconds": 0]

        let decoded = try #require(WatchHandoff(dictionary: context))

        #expect(decoded.boltBestSeconds == nil)
        #expect(
            WatchHandoff(userId: id, boltBestSeconds: 0) == WatchHandoff(userId: id),
            "a zero and an absence describe the same person, so they must compare equal"
        )
    }

    /// The watch must not adopt an identity it cannot use — a half-read context
    /// is ignored, leaving it anonymous rather than attributing sessions to
    /// something the server will reject.
    @Test("A context with no usable id is refused")
    func refusesAnUnusableContext() {
        // Written as a loop rather than `@Test(arguments:)` because a case here
        // is a `[String: Any]`, which Swift Testing cannot carry across the
        // isolation boundary a parameterised test runs each case in.
        let unusable: [[String: Any]] = [
            [:],
            ["userId": "not-a-uuid"],
            ["boltBestSeconds": 30],
        ]

        for context in unusable {
            #expect(WatchHandoff(dictionary: context) == nil)
        }
    }
}
