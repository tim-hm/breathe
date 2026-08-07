//! BOLT-score SQL.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::super::errors::JourneyError;
use crate::identity::UserId;

/// Stores a score unless the caller has already sent that one.
///
/// `ON CONFLICT DO NOTHING` on `(user_id, client_score_id)`, the same contract
/// `sessions::repository::insert_sessions` offers: both streams drain through
/// one opportunistic queue on the client, so a retry has to be free on both.
///
/// The caller's identity and the client-minted score id are different types
/// rather than two adjacent `Uuid`s. They name different things, and a swap
/// between them attributes a score to nobody and compiles perfectly.
pub async fn insert_bolt_score(
    pool: &PgPool,
    user_id: UserId,
    client_score_id: Uuid,
    seconds: i32,
    measured_at: Option<DateTime<Utc>>,
) -> Result<(), JourneyError> {
    sqlx::query!(
        "INSERT INTO bolt_scores (user_id, client_score_id, seconds, measured_at)
         VALUES ($1, $2, $3, coalesce($4, now()))
         ON CONFLICT (user_id, client_score_id) DO NOTHING",
        user_id.0,
        client_score_id,
        seconds,
        measured_at
    )
    .execute(pool)
    .await?;

    Ok(())
}

/// The caller's best score, or `None` before they have taken the test.
pub async fn best_bolt_score(pool: &PgPool, user_id: UserId) -> Result<Option<i32>, JourneyError> {
    let best = sqlx::query_scalar!(
        "SELECT max(seconds) FROM bolt_scores WHERE user_id = $1",
        user_id.0
    )
    .fetch_one(pool)
    .await?;

    Ok(best)
}

/// The three folds `super::service::bolt_snapshot` serves. `best` and `latest`
/// are `None` together, exactly when `count` is zero — one statement over one
/// history cannot answer otherwise.
pub struct BoltAggregateRow {
    pub best: Option<i32>,
    pub latest: Option<i32>,
    pub count: i64,
}

/// Best, latest, and count in one statement, so the three figures were true
/// together — split into three reads they could tear around a concurrent
/// insert, and a snapshot would report a count its best does not cover.
///
/// The first read of this table in date order, via the `array_agg` ordering.
/// It runs without an index on `measured_at` deliberately: the existing index
/// narrows the scan to the caller's own rows, and one person's test history is
/// dozens of rows, not thousands — too small an aggregate to be worth a write
/// on every score. The id tie-break is what makes "latest" deterministic when
/// two scores share a `measured_at`, which two defaulted inserts in one sync
/// can.
pub async fn bolt_aggregate(
    pool: &PgPool,
    user_id: UserId,
) -> Result<BoltAggregateRow, JourneyError> {
    let row = sqlx::query_as!(
        BoltAggregateRow,
        r#"SELECT max(seconds) AS best,
                (array_agg(seconds ORDER BY measured_at DESC, client_score_id DESC))[1] AS latest,
                count(*) AS "count!"
         FROM bolt_scores
         WHERE user_id = $1"#,
        user_id.0
    )
    .fetch_one(pool)
    .await?;

    Ok(row)
}
