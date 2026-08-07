//! Domain enums for the leaderboards.
//!
//! Neither is a Postgres type: a board is a choice of query, not a value that
//! gets stored, so these exist purely to keep the proto zero values from
//! reaching the repository as a third "no board asked for" case.

/// Which measure a board ranks people by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaderboardBoard {
    /// Consecutive local days ending today or yesterday.
    Streak,
    /// Minutes breathed in the last thirty days.
    Minutes30d,
    /// Best BOLT-style controlled pause, in seconds.
    Bolt,
}

/// Who a board is drawn from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaderboardScope {
    Global,
    /// Only people sharing the caller's birth-year band.
    AgeBand,
}
