//! Leaderboard SQL, in two halves that used to be one.
//!
//! The fold — three rankings' worth of gaps-and-islands, rolling sums and
//! per-person maxima — runs on refresh, once per board per day boundary, and
//! lands one narrow row per person in `leaderboard_snapshot`. The read ranks
//! those rows and never touches `sessions` or `bolt_scores` at all.
//!
//! Both halves stay in SQL for the reason they always did: ranking needs every
//! candidate row to answer, and dragging the install base's history across the
//! wire to sort it would be a query that gets slower for exactly the people who
//! use the app most.

use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::super::errors::JourneyError;
use super::types::LeaderboardBoard;
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

/// Ranks one snapshotted board, and finds the caller on it.
///
/// One query for all three boards, where there used to be three that differed
/// only in a `scored` CTE: what a board measures is now decided at refresh
/// time, so by the time anything is read they are the same shape over the same
/// table. The ranking stays here rather than in the snapshot because it depends
/// on the scope the caller asked for — see `0013_leaderboard_snapshot.sql` for
/// why storing it per band would cost eight times as much to save a sort.
pub async fn board(
    pool: &PgPool,
    caller: UserId,
    board: LeaderboardBoard,
    utc_offset_minutes: i32,
    band: Option<BirthYearBand>,
    limit: i64,
) -> Result<Vec<LeaderboardRow>, JourneyError> {
    let rows = sqlx::query_as!(
        LeaderboardRow,
        r#"WITH ranked AS (
            SELECT u.id, u.display_name, s.value,
                   rank() OVER (ORDER BY s.value DESC) AS rank
            FROM leaderboard_snapshot s
            JOIN users u ON u.id = s.user_id
            WHERE s.board = $2 AND s.utc_offset_minutes = $3
              AND ($4::birth_year_band IS NULL OR u.birth_year_band = $4)
        ),
        placed AS (
            SELECT id, display_name, value, rank,
                   row_number() OVER (
                       PARTITION BY display_name IS NOT NULL ORDER BY rank, display_name
                   ) AS listed
            FROM ranked
        )
        SELECT id AS "user_id!", display_name, value AS "value!", rank AS "rank!",
               (display_name IS NOT NULL AND listed <= $5) AS "on_board!"
        FROM placed
        WHERE id = $1 OR (display_name IS NOT NULL AND listed <= $5)
        ORDER BY rank, display_name"#,
        caller.0,
        board as _,
        utc_offset_minutes,
        band as _,
        limit
    )
    .fetch_all(pool)
    .await?;

    Ok(rows)
}

/// Whether a board's snapshot is young enough to serve.
///
/// Deliberately outside the refresh transaction and taking no lock. This is the
/// answer on almost every request, and the moment it needs a row lock every
/// caller reading the same board queues behind every other.
pub async fn is_fresh(
    pool: &PgPool,
    board: LeaderboardBoard,
    utc_offset_minutes: i32,
    ttl_seconds: f64,
) -> Result<bool, JourneyError> {
    let fresh = sqlx::query_scalar!(
        r#"SELECT EXISTS (
            SELECT 1 FROM leaderboard_refresh
            WHERE board = $1 AND utc_offset_minutes = $2
              AND refreshed_at > now() - make_interval(secs => $3)
        ) AS "fresh!""#,
        board as _,
        utc_offset_minutes,
        ttl_seconds
    )
    .fetch_one(pool)
    .await?;

    Ok(fresh)
}

/// Re-folds one board at one day boundary, unless somebody else just did.
///
/// The whole thing is one transaction around the `leaderboard_refresh` row,
/// which serves as both the mutex and the clock. A request that finds the key
/// stale creates the row if it is missing, locks it, and re-asks the question
/// it already asked outside the lock — so a burst of callers arriving on an
/// expired board produces exactly one fold and a queue of no-ops behind it,
/// rather than one fold each.
///
/// The lock is not merely an economy. The fold deletes a key's rows and
/// reinserts them, and two such transactions interleaved under READ COMMITTED
/// each delete the rows visible to their own snapshot and then collide on the
/// primary key.
pub async fn refresh(
    pool: &PgPool,
    board: LeaderboardBoard,
    utc_offset_minutes: i32,
    ttl_seconds: f64,
) -> Result<(), JourneyError> {
    let mut tx = pool.begin().await?;

    sqlx::query!(
        "INSERT INTO leaderboard_refresh (board, utc_offset_minutes, refreshed_at)
         VALUES ($1, $2, '-infinity')
         ON CONFLICT (board, utc_offset_minutes) DO NOTHING",
        board as _,
        utc_offset_minutes
    )
    .execute(&mut *tx)
    .await?;

    let fresh = sqlx::query_scalar!(
        r#"SELECT refreshed_at > now() - make_interval(secs => $3) AS "fresh!"
           FROM leaderboard_refresh
           WHERE board = $1 AND utc_offset_minutes = $2
           FOR UPDATE"#,
        board as _,
        utc_offset_minutes,
        ttl_seconds
    )
    .fetch_one(&mut *tx)
    .await?;

    if fresh {
        // Somebody folded this key while this transaction waited for the lock.
        // Rolled back rather than committed: the row it may have inserted above
        // is `-infinity`, which would otherwise persist as a key claiming never
        // to have been folded next to the rows that were.
        tx.rollback().await?;
        return Ok(());
    }

    sqlx::query!(
        "DELETE FROM leaderboard_snapshot WHERE board = $1 AND utc_offset_minutes = $2",
        board as _,
        utc_offset_minutes
    )
    .execute(&mut *tx)
    .await?;

    fold(&mut tx, board, utc_offset_minutes).await?;

    sqlx::query!(
        "UPDATE leaderboard_refresh SET refreshed_at = now()
         WHERE board = $1 AND utc_offset_minutes = $2",
        board as _,
        utc_offset_minutes
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}

/// Computes one board's scores into the snapshot.
///
/// The three statements share one shape and differ only in what they measure.
/// They are written out rather than composed because `sqlx::query!` checks a
/// literal string against the real schema at compile time, and a string built
/// at runtime would trade that guarantee for the removal of about ten lines.
///
/// The streak fold's `recent` CTE is what keeps it bounded. Only somebody who
/// breathed within the last local day or two can hold a current streak, so the
/// gaps-and-islands fold runs over that population rather than over everyone
/// who has ever used the app. It still reads each of those people's whole
/// history — a run's length is not knowable from its tail — so what the window
/// bounds is how many people are folded, not how many rows each contributes.
/// Three UTC days is the smallest window that is a superset of "local yesterday
/// or later" at every offset from -12:00 to +14:00; the final `WHERE` still
/// applies the exact local-day test, so the widening changes no answer.
///
/// The minutes board's `HAVING` drops anybody short of a whole minute rather
/// than recording them at zero — a board of zeroes is worse than a short board.
async fn fold(
    tx: &mut Transaction<'_, Postgres>,
    board: LeaderboardBoard,
    utc_offset_minutes: i32,
) -> Result<(), JourneyError> {
    match board {
        LeaderboardBoard::Streak => {
            sqlx::query!(
                "INSERT INTO leaderboard_snapshot (board, utc_offset_minutes, user_id, value)
                 WITH recent AS (
                     SELECT DISTINCT user_id
                     FROM sessions
                     WHERE started_at >= now() - interval '3 days'
                 ),
                 days AS (
                     SELECT DISTINCT
                         s.user_id,
                         ((s.started_at AT TIME ZONE 'UTC') + make_interval(mins => $1))::date AS day
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
                 )
                 SELECT 'STREAK'::leaderboard_board, $1, user_id, max(length)
                 FROM runs
                 WHERE last_day >= ((now() AT TIME ZONE 'UTC') + make_interval(mins => $1))::date - 1
                 GROUP BY user_id",
                utc_offset_minutes
            )
            .execute(&mut **tx)
            .await?;
        }
        LeaderboardBoard::Minutes30d => {
            sqlx::query!(
                "INSERT INTO leaderboard_snapshot (board, utc_offset_minutes, user_id, value)
                 SELECT 'MINUTES_30D'::leaderboard_board, $1, user_id,
                        (sum(duration_ms) / 60000)::integer
                 FROM sessions
                 WHERE started_at >= now() - interval '30 days'
                 GROUP BY user_id
                 HAVING sum(duration_ms) >= 60000",
                utc_offset_minutes
            )
            .execute(&mut **tx)
            .await?;
        }
        LeaderboardBoard::Bolt => {
            sqlx::query!(
                "INSERT INTO leaderboard_snapshot (board, utc_offset_minutes, user_id, value)
                 SELECT 'BOLT'::leaderboard_board, $1, user_id, max(seconds)
                 FROM bolt_scores
                 GROUP BY user_id",
                utc_offset_minutes
            )
            .execute(&mut **tx)
            .await?;
        }
    }

    Ok(())
}
