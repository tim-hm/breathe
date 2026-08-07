//! Session SQL.
//!
//! One append-only table and a window function over it. Streaks are folded here
//! rather than in Rust because they need the whole history to answer, and
//! dragging every row of it across the wire to count calendar days would be a
//! query that gets slower for the people who use the app most.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::super::errors::JourneyError;
use super::types::SessionCursor;
use crate::identity::UserId;

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
    user_id: UserId,
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
        user_id.0,
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

/// Removes the caller's sessions with these ids and reports how many went.
///
/// Scoped to `user_id` in the `WHERE` rather than trusted from the ids alone:
/// a `client_session_id` is minted on a device and is not unique across people,
/// so a delete keyed on the id alone would let one caller erase another's
/// history by sending a value they had no way of knowing was in use.
///
/// The affected-row count is what tells a client whose tombstone list has run
/// ahead of the server that there was nothing left to forget — and unlike
/// `insert_sessions`, which needs `RETURNING` to learn *which* rows were new,
/// nothing here reads the ids back.
pub async fn delete_sessions(
    pool: &PgPool,
    user_id: UserId,
    client_session_ids: &[Uuid],
) -> Result<u64, JourneyError> {
    let deleted = sqlx::query!(
        "DELETE FROM sessions
         WHERE user_id = $1 AND client_session_id = ANY($2::uuid[])",
        user_id.0,
        client_session_ids
    )
    .execute(pool)
    .await?;

    Ok(deleted.rows_affected())
}

/// Sums one person's whole history.
///
/// Deliberately unwindowed: these are lifetime figures, so there is no date
/// predicate to narrow it and the cost grows with how much somebody has
/// practised. That is the trade the "no counter columns" rule buys — nothing to
/// drift, at the price of a scan on a screen opened a few times a day.
pub async fn totals(pool: &PgPool, user_id: UserId) -> Result<TotalsRow, JourneyError> {
    let row = sqlx::query_as!(
        TotalsRow,
        r#"SELECT
            count(*) AS "sessions!",
            coalesce(sum(breath_count), 0)::bigint AS "breaths!",
            coalesce(sum(duration_ms), 0)::bigint AS "duration_ms!"
         FROM sessions
         WHERE user_id = $1"#,
        user_id.0
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
    user_id: UserId,
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
        user_id.0,
        utc_offset_minutes
    )
    .fetch_one(pool)
    .await?;

    Ok(row)
}

/// One page of the caller's history, newest first.
///
/// Ordered on both key columns rather than `started_at` alone. The second is not
/// decoration: two sessions sharing an instant have no order without it, so a
/// page boundary between them would drop one and repeat the other on the very
/// path — a restore after a reinstall — where a dropped session is gone for
/// good. The same pair is what `after` seeks on, as a row-value comparison so
/// the planner walks `sessions_user_started_at_idx` from the cursor rather than
/// counting past everything before it.
pub async fn recent_sessions(
    pool: &PgPool,
    user_id: UserId,
    limit: i64,
    after: Option<SessionCursor>,
) -> Result<Vec<SessionRow>, JourneyError> {
    let rows = sqlx::query_as!(
        SessionRow,
        "SELECT client_session_id, technique_slug, started_at,
                duration_ms, cycles_completed, breath_count, completed
         FROM sessions
         WHERE user_id = $1
           AND ($3::timestamptz IS NULL
                OR (started_at, client_session_id) < ($3, $4::uuid))
         ORDER BY started_at DESC, client_session_id DESC
         LIMIT $2",
        user_id.0,
        limit,
        after.map(|cursor| cursor.started_at),
        after.map(|cursor| cursor.client_session_id)
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}
