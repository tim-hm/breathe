//! Domain enums for the leaderboards.
//!
//! Both exist to keep the proto zero values from reaching the repository as a
//! third "no board asked for" case. Only one of them is also a Postgres type: a
//! board names a snapshot key, whereas a scope is still a choice made at read
//! time and never stored.

/// Which measure a board ranks people by.
///
/// Mirrors the `leaderboard_board` Postgres enum. Every variant is renamed
/// explicitly rather than through `rename_all`, for the reason `BirthYearBand`
/// is: a label containing digits has no case convention anybody should have to
/// guess at.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(type_name = "leaderboard_board")]
pub enum LeaderboardBoard {
    /// Consecutive local days ending today or yesterday.
    #[sqlx(rename = "STREAK")]
    Streak,
    /// Minutes breathed in the last thirty days.
    #[sqlx(rename = "MINUTES_30D")]
    Minutes30d,
    /// Best BOLT-style controlled pause, in seconds.
    #[sqlx(rename = "BOLT")]
    Bolt,
}

/// Who a board is drawn from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaderboardScope {
    Global,
    /// Only people sharing the caller's birth-year band.
    AgeBand,
}
