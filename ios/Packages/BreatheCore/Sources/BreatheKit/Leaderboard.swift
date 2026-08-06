import Foundation

/// Which board is being looked at.
///
/// Every board measures consistency or a controlled test. There is deliberately
/// no maximal-hold board: a contest over how long somebody can hold their breath
/// rewards exactly the behaviour this app tells people not to do.
public enum LeaderboardBoard: String, Sendable, CaseIterable, Identifiable {
    case streak
    case minutes30d
    case bolt

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .streak: "Streak"
        case .minutes30d: "Minutes"
        case .bolt: "Pause"
        }
    }

    /// What the board is actually measuring, for a caption under the picker.
    public var detail: String {
        switch self {
        case .streak: "Days in a row, right now."
        case .minutes30d: "Minutes breathed in the last 30 days."
        case .bolt: "Best comfortable pause."
        }
    }

    /// A value in this board's own unit.
    public func formatted(_ value: Int) -> String {
        switch self {
        case .streak: value == 1 ? "1 day" : "\(value) days"
        case .minutes30d: value == 1 ? "1 min" : "\(value) min"
        case .bolt: "\(value)s"
        }
    }
}

/// Who a board is drawn from.
public enum LeaderboardScope: String, Sendable, CaseIterable, Identifiable {
    case global
    /// Only people who share the reader's birth-year band. Needs one to be set.
    case ageBand

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .global: "Everyone"
        case .ageBand: "My decade"
        }
    }
}

/// One named person on a board.
public struct LeaderboardEntry: Sendable, Equatable, Identifiable {
    /// Equal values share a rank, and the ranking counts everybody with a
    /// score — so consecutive entries may skip a number where the person in
    /// between has not chosen a display name.
    public let rank: Int
    public let displayName: String
    public let value: Int

    /// The name, which the server has already made unique.
    public var id: String {
        displayName
    }

    public init(rank: Int, displayName: String, value: Int) {
        self.rank = rank
        self.displayName = displayName
        self.value = value
    }
}

/// Where the reader stands, whether or not anybody else can see them.
public struct LeaderboardStanding: Sendable, Equatable {
    /// `nil` when there is nothing to rank yet.
    public let rank: Int?
    public let value: Int
    /// Whether other people can see them here. False until they set a display
    /// name, which is the whole of the opt-in.
    public let listed: Bool

    public init(rank: Int?, value: Int, listed: Bool) {
        self.rank = rank
        self.value = value
        self.listed = listed
    }

    /// "1st", "2nd", "3rd" — a bare number beside "You're" reads as a score
    /// rather than a place. Localised, because the suffix is not English-only,
    /// and here beside `LeaderboardBoard.formatted(_:)` so that board values and
    /// board ranks are formatted in the same place.
    public var formattedRank: String? {
        rank.map { Self.ordinal.string(from: NSNumber(value: $0)) ?? "\($0)" }
    }

    private static let ordinal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()
}

/// A board as it was when it was fetched.
public struct Leaderboard: Sendable, Equatable {
    public let board: LeaderboardBoard
    public let scope: LeaderboardScope
    /// Best first. Empty is a normal state on a young board where nobody has
    /// opted in.
    public let entries: [LeaderboardEntry]
    public let standing: LeaderboardStanding

    public init(
        board: LeaderboardBoard,
        scope: LeaderboardScope,
        entries: [LeaderboardEntry],
        standing: LeaderboardStanding
    ) {
        self.board = board
        self.scope = scope
        self.entries = entries
        self.standing = standing
    }
}
