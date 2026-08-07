//! Leaderboard SQL.
//!
//! Three rankings over the same two tables. Each is folded here rather than in
//! Rust because ranking needs every candidate row to answer, and dragging the
//! install base's history across the wire to sort it would be a query that gets
//! slower for exactly the people who use the app most.

use sqlx::PgPool;
use uuid::Uuid;

use super::super::errors::JourneyError;
use crate::features::profile::types::BirthYearBand;
use crate::identity::UserId;

/// One person's standing on a board.
pub struct LeaderboardRow {
    pub user_id: Uuid,
    /// `None` only ever for the caller's own row: an entry without a name is
    /// counted in the ranking and never listed.
    pub display_name: Option<String>,
    pub value: i32,
    pub rank: i64,
    /// Whether this row is one of the board's leading entries, as opposed to
    /// the caller's own row fetched alongside them.
    pub on_board: bool,
}

/// Ranks current streaks, in the caller's local days.
///
/// The three board queries below share one shape and differ only in the
/// `scored` CTE. They are written out rather than composed because
/// `sqlx::query_as!` checks a literal string against the real schema at compile
/// time, and a string built at runtime would trade that guarantee for the
/// removal of about ten lines.
///
/// The `recent` CTE is what keeps this bounded. Only somebody who breathed
/// within the last local day or two can hold a current streak, so the
/// gaps-and-islands fold runs over that population rather than over everyone who
/// has ever used the app. It still reads each of those people's whole history —
/// a run's length is not knowable from its tail — so what the window bounds is
/// how many people are folded, not how many rows each contributes. Three UTC
/// days is the smallest window that is a superset of "local yesterday or later"
/// at every offset from -12:00 to +14:00; `scored` still applies the exact
/// local-day test, so the widening changes no answer.
pub async fn streak_board(
    pool: &PgPool,
    caller: UserId,
    band: Option<BirthYearBand>,
    limit: i64,
    utc_offset_minutes: i32,
) -> Result<Vec<LeaderboardRow>, JourneyError> {
    let rows = sqlx::query_as!(
        LeaderboardRow,
        r#"WITH recent AS (
            SELECT DISTINCT user_id
            FROM sessions
            WHERE started_at >= now() - interval '3 days'
        ),
        days AS (
            SELECT DISTINCT
                s.user_id,
                ((s.started_at AT TIME ZONE 'UTC') + make_interval(mins => $4))::date AS day
            FROM sessions s
            JOIN recent r ON r.user_id = s.user_id
        ),
        grouped AS (
            SELECT user_id, day,
                   day - (row_number() OVER (PARTITION BY user_id ORDER BY day))::integer AS run
            FROM days
        ),
        runs AS (
            SELECT user_id, max(day) AS last_day, count(*)::integer AS length
            FROM grouped
            GROUP BY user_id, run
        ),
        scored AS (
            SELECT user_id, max(length) AS value
            FROM runs
            WHERE last_day >= ((now() AT TIME ZONE 'UTC') + make_interval(mins => $4))::date - 1
            GROUP BY user_id
        ),
        ranked AS (
            SELECT u.id, u.display_name, s.value,
                   rank() OVER (ORDER BY s.value DESC) AS rank
            FROM scored s
            JOIN users u ON u.id = s.user_id
            WHERE $2::birth_year_band IS NULL OR u.birth_year_band = $2
        ),
        placed AS (
            SELECT id, display_name, value, rank,
                   row_number() OVER (
                       PARTITION BY display_name IS NOT NULL ORDER BY rank, display_name
                   ) AS listed
            FROM ranked
        )
        SELECT id AS "user_id!", display_name, value AS "value!", rank AS "rank!",
               (display_name IS NOT NULL AND listed <= $3) AS "on_board!"
        FROM placed
        WHERE id = $1 OR (display_name IS NOT NULL AND listed <= $3)
        ORDER BY rank, display_name"#,
        caller.0,
        band as _,
        limit,
        utc_offset_minutes
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Ranks minutes breathed over a rolling thirty days.
///
/// The `HAVING` drops anybody short of a whole minute rather than listing them
/// at zero — a board of zeroes is worse than a short board.
pub async fn minutes_board(
    pool: &PgPool,
    caller: UserId,
    band: Option<BirthYearBand>,
    limit: i64,
) -> Result<Vec<LeaderboardRow>, JourneyError> {
    let rows = sqlx::query_as!(
        LeaderboardRow,
        r#"WITH scored AS (
            SELECT user_id, (sum(duration_ms) / 60000)::integer AS value
            FROM sessions
            WHERE started_at >= now() - interval '30 days'
            GROUP BY user_id
            HAVING sum(duration_ms) >= 60000
        ),
        ranked AS (
            SELECT u.id, u.display_name, s.value,
                   rank() OVER (ORDER BY s.value DESC) AS rank
            FROM scored s
            JOIN users u ON u.id = s.user_id
            WHERE $2::birth_year_band IS NULL OR u.birth_year_band = $2
        ),
        placed AS (
            SELECT id, display_name, value, rank,
                   row_number() OVER (
                       PARTITION BY display_name IS NOT NULL ORDER BY rank, display_name
                   ) AS listed
            FROM ranked
        )
        SELECT id AS "user_id!", display_name, value AS "value!", rank AS "rank!",
               (display_name IS NOT NULL AND listed <= $3) AS "on_board!"
        FROM placed
        WHERE id = $1 OR (display_name IS NOT NULL AND listed <= $3)
        ORDER BY rank, display_name"#,
        caller.0,
        band as _,
        limit
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Ranks best controlled pauses.
pub async fn bolt_board(
    pool: &PgPool,
    caller: UserId,
    band: Option<BirthYearBand>,
    limit: i64,
) -> Result<Vec<LeaderboardRow>, JourneyError> {
    let rows = sqlx::query_as!(
        LeaderboardRow,
        r#"WITH scored AS (
            SELECT user_id, max(seconds) AS value
            FROM bolt_scores
            GROUP BY user_id
        ),
        ranked AS (
            SELECT u.id, u.display_name, s.value,
                   rank() OVER (ORDER BY s.value DESC) AS rank
            FROM scored s
            JOIN users u ON u.id = s.user_id
            WHERE $2::birth_year_band IS NULL OR u.birth_year_band = $2
        ),
        placed AS (
            SELECT id, display_name, value, rank,
                   row_number() OVER (
                       PARTITION BY display_name IS NOT NULL ORDER BY rank, display_name
                   ) AS listed
            FROM ranked
        )
        SELECT id AS "user_id!", display_name, value AS "value!", rank AS "rank!",
               (display_name IS NOT NULL AND listed <= $3) AS "on_board!"
        FROM placed
        WHERE id = $1 OR (display_name IS NOT NULL AND listed <= $3)
        ORDER BY rank, display_name"#,
        caller.0,
        band as _,
        limit
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
