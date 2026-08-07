import Foundation
import OndAPI
@testable import OndKit
import Testing

/// The outbound half of the leaderboard contract, which is the half nothing
/// else holds.
///
/// The server pins the inbound half with `an_unspecified_board_or_scope_is_refused`,
/// and that is exactly what leaves this side unguarded: both enums have the same
/// arity as their proto counterparts, so a swapped arm type-checks, produces a
/// request the server answers happily, and `Leaderboard(board: board, …)` labels
/// the answer with the board that was *asked for*. The person reads the wrong
/// board under the right heading, and neither compiler nor server can see it.
@Suite("Mapping leaderboard choices onto the wire")
struct LeaderboardDecodingTests {
    @Test("Each board maps to the proto case that names it, and no other")
    func boardsMapOneForOne() {
        #expect(LeaderboardBoard.streak.proto == .streak)
        #expect(LeaderboardBoard.minutes30d.proto == .minutes30D)
        #expect(LeaderboardBoard.bolt.proto == .bolt)
    }

    @Test("Each scope maps to the proto case that names it, and no other")
    func scopesMapOneForOne() {
        #expect(LeaderboardScope.global.proto == .global)
        #expect(LeaderboardScope.ageBand.proto == .ageBand)
    }

    /// The proto's zero value is the server's refusal, so an arm reaching it
    /// turns a board somebody picked into an `INVALID_ARGUMENT` — and this app
    /// reads that as "leaderboards need a connection". Written over `allCases`
    /// so a board added later is covered before anyone thinks to add a line.
    @Test("Nothing a person can pick maps onto the proto zero value")
    func nothingMapsOntoUnspecified() {
        for board in LeaderboardBoard.allCases {
            #expect(board.proto != .unspecified)
        }
        for scope in LeaderboardScope.allCases {
            #expect(scope.proto != .unspecified)
        }
    }
}
