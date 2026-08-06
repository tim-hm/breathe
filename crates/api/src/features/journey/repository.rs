//! Journey SQL.
//!
//! Two append-only tables and a handful of window functions over them. Streaks
//! and boards are folded here rather than in Rust because both need the whole
//! history to answer, and dragging every row of it across the wire to count
//! calendar days would be a query that gets slower for the people who use the
//! app most.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::JourneyError;
use crate::features::profile::types::BirthYearBand;

/// One row of `sessions`, in both directions.
pub struct SessionRow {
    pub client_session_id: Uuid,
    pub technique_slug: String,
    pub started_at: DateTime<Utc>,
    pub duration_ms: i32,
    pub cycles_completed: i32,
    pub breath_count: i32,
    pub completed: bool,
}

/// Everything the journey screen counts, summed over one person's history.
pub struct TotalsRow {
    pub sessions: i64,
    pub breaths: i64,
    /// Summed rather than pre-divided, so a hundred short sessions do not each
    /// lose their remainder on the way to a minute count.
    pub duration_ms: i64,
}

/// The two streak numbers, which are one query because they are two folds of
/// the same list of days.
pub struct StreakRow {
    pub current: i32,
    pub best: i32,
}

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

/// Stores the sessions the server has not seen and reports how many were new.
///
/// `ON CONFLICT DO NOTHING` on the primary key is the whole of the idempotency:
/// a client that re-sends a batch, syncs from two devices, or retries a request
/// that actually succeeded converges on the same rows. `RETURNING` counts only
/// the tuples that were really inserted, so the answer is the database's rather
/// than an assumption about what the client already had.
///
/// One statement over unnested arrays rather than a loop: a fortnight of offline
/// sessions is one round trip and one transaction, which is also what makes the
/// count atomic.
pub async fn insert_sessions(
    pool: &PgPool,
    user_id: Uuid,
    sessions: &[SessionRow],
) -> Result<usize, JourneyError> {
    let ids: Vec<Uuid> = sessions.iter().map(|s| s.client_session_id).collect();
    let slugs: Vec<String> = sessions.iter().map(|s| s.technique_slug.clone()).collect();
    let started_at: Vec<DateTime<Utc>> = sessions.iter().map(|s| s.started_at).collect();
    let durations: Vec<i32> = sessions.iter().map(|s| s.duration_ms).collect();
    let cycles: Vec<i32> = sessions.iter().map(|s| s.cycles_completed).collect();
    let breaths: Vec<i32> = sessions.iter().map(|s| s.breath_count).collect();
    let completed: Vec<bool> = sessions.iter().map(|s| s.completed).collect();

    let inserted = sqlx::query_scalar!(
        "INSERT INTO sessions (
            user_id, client_session_id, technique_slug, started_at,
            duration_ms, cycles_completed, breath_count, completed
         )
         SELECT $1, s.id, s.slug, s.started_at, s.duration_ms, s.cycles, s.breaths, s.completed
         FROM UNNEST(
                $2::uuid[], $3::text[], $4::timestamptz[],
                $5::integer[], $6::integer[], $7::integer[], $8::boolean[]
              ) AS s(id, slug, started_at, duration_ms, cycles, breaths, completed)
         ON CONFLICT (user_id, client_session_id) DO NOTHING
         RETURNING client_session_id",
        user_id,
        &ids,
        &slugs,
        &started_at,
        &durations,
        &cycles,
        &breaths,
        &completed
    )
    .fetch_all(pool)
    .await?;

    Ok(inserted.len())
}

pub async fn totals(pool: &PgPool, user_id: Uuid) -> Result<TotalsRow, JourneyError> {
    let row = sqlx::query_as!(
        TotalsRow,
        r#"SELECT
            count(*) AS "sessions!",
            coalesce(sum(breath_count), 0)::bigint AS "breaths!",
            coalesce(sum(duration_ms), 0)::bigint AS "duration_ms!"
         FROM sessions
         WHERE user_id = $1"#,
        user_id
    )
    .fetch_one(pool)
    .await?;

    Ok(row)
}

/// Folds one person's sessions into a current and a best streak.
///
/// The gaps-and-islands fold: number the distinct local days, subtract the row
/// number from the date, and every consecutive run collapses to one constant —
/// so counting runs is a `GROUP BY` rather than a cursor walk.
///
/// Two decisions worth knowing. The local day comes from the caller's offset
/// rather than a stored zone, so a session at 23:30 belongs to the day the
/// person was living in, not to tomorrow in UTC. And the current streak accepts
/// a run ending yesterday: a streak is not broken until a whole local day has
/// gone by without a session, so somebody who has not breathed yet this morning
/// has not lost anything.
pub async fn streaks(
    pool: &PgPool,
    user_id: Uuid,
    utc_offset_minutes: i32,
) -> Result<StreakRow, JourneyError> {
    let row = sqlx::query_as!(
        StreakRow,
        r#"WITH days AS (
            SELECT DISTINCT
                ((started_at AT TIME ZONE 'UTC') + make_interval(mins => $2))::date AS day
            FROM sessions
            WHERE user_id = $1
        ),
        grouped AS (
            SELECT day, day - (row_number() OVER (ORDER BY day))::integer AS run
            FROM days
        ),
        runs AS (
            SELECT max(day) AS last_day, count(*)::integer AS length
            FROM grouped
            GROUP BY run
        )
        SELECT
            coalesce(max(length) FILTER (
                WHERE last_day >= ((now() AT TIME ZONE 'UTC') + make_interval(mins => $2))::date - 1
            ), 0) AS "current!",
            coalesce(max(length), 0) AS "best!"
        FROM runs"#,
        user_id,
        utc_offset_minutes
    )
    .fetch_one(pool)
    .await?;

    Ok(row)
}

pub async fn recent_sessions(
    pool: &PgPool,
    user_id: Uuid,
    limit: i64,
) -> Result<Vec<SessionRow>, JourneyError> {
    let rows = sqlx::query_as!(
        SessionRow,
        "SELECT client_session_id, technique_slug, started_at,
                duration_ms, cycles_completed, breath_count, completed
         FROM sessions
         WHERE user_id = $1
         ORDER BY started_at DESC
         LIMIT $2",
        user_id,
        limit
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Stores a score unless the caller has already sent that one.
///
/// `ON CONFLICT DO NOTHING` on `(user_id, client_score_id)`, the same contract
/// `insert_sessions` offers: both streams drain through one opportunistic queue
/// on the client, so a retry has to be free on both.
pub async fn insert_bolt_score(
    pool: &PgPool,
    user_id: Uuid,
    client_score_id: Uuid,
    seconds: i32,
    measured_at: Option<DateTime<Utc>>,
) -> Result<(), JourneyError> {
    sqlx::query!(
        "INSERT INTO bolt_scores (user_id, client_score_id, seconds, measured_at)
         VALUES ($1, $2, $3, coalesce($4, now()))
         ON CONFLICT (user_id, client_score_id) DO NOTHING",
        user_id,
        client_score_id,
        seconds,
        measured_at
    )
    .execute(pool)
    .await?;

    Ok(())
}

/// The caller's best score, or `None` before they have taken the test.
pub async fn best_bolt_score(pool: &PgPool, user_id: Uuid) -> Result<Option<i32>, JourneyError> {
    let best = sqlx::query_scalar!(
        "SELECT max(seconds) FROM bolt_scores WHERE user_id = $1",
        user_id
    )
    .fetch_one(pool)
    .await?;

    Ok(best)
}

/// Ranks current streaks, in the caller's local days.
///
/// The three board queries below share one shape and differ only in the
/// `scored` CTE. They are written out rather than composed because
/// `sqlx::query_as!` checks a literal string against the real schema at compile
/// time, and a string built at runtime would trade that guarantee for the
/// removal of about ten lines.
pub async fn streak_board(
    pool: &PgPool,
    caller: Uuid,
    band: Option<BirthYearBand>,
    limit: i64,
    utc_offset_minutes: i32,
) -> Result<Vec<LeaderboardRow>, JourneyError> {
    let rows = sqlx::query_as!(
        LeaderboardRow,
        r#"WITH days AS (
            SELECT DISTINCT
                user_id,
                ((started_at AT TIME ZONE 'UTC') + make_interval(mins => $4))::date AS day
            FROM sessions
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
        caller,
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
    caller: Uuid,
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
        caller,
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
    caller: Uuid,
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
        caller,
        band as _,
        limit
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
