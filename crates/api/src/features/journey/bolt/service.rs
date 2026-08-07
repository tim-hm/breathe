//! Business logic — validates a submitted measurement and answers whether it is
//! a personal best.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use sqlx::PgPool;
use uuid::Uuid;

use super::super::errors::JourneyError;
use super::super::wire::{counted, timestamp_from_proto};
use super::repository;
use super::types::BoltSnapshot;
use crate::identity::UserId;
use crate::proto::ond::v1 as pb;

/// Matches the `CHECK` on `bolt_scores.seconds`.
const MAX_BOLT_SECONDS: u32 = 600;

/// Records one controlled pause and says where it leaves the person.
///
/// Idempotent on `(caller, client_score_id)`, because scores drain through the
/// same opportunistic queue as sessions and a resend has to be free — without
/// it, a duplicate would hide behind `max(seconds)` on every board.
///
/// Whether it is a personal best is the server's answer rather than the
/// client's: a device that was offline for three tests does not hold the history
/// to compare against.
pub async fn record_bolt_score(
    pool: &PgPool,
    user_id: UserId,
    request: pb::RecordBoltScoreRequest,
) -> Result<pb::RecordBoltScoreResponse, JourneyError> {
    if request.seconds == 0 || request.seconds > MAX_BOLT_SECONDS {
        return Err(JourneyError::Invalid(format!(
            "`seconds` must be between 1 and {MAX_BOLT_SECONDS}"
        )));
    }
    let seconds = i32::try_from(request.seconds)
        .map_err(|_| JourneyError::Invalid("`seconds` is out of range".to_owned()))?;

    let client_score_id = Uuid::parse_str(&request.client_score_id).map_err(|_| {
        JourneyError::Invalid(format!(
            "`client_score_id` `{}` is not a UUID",
            request.client_score_id
        ))
    })?;

    let measured_at = request
        .measured_at
        .map(|stamp| timestamp_from_proto(&stamp, "measured_at"))
        .transpose()?;

    // Read before the insert, because "is this a personal best" is a question
    // about the history that existed before it — asking afterwards would always
    // answer yes.
    let previous_best = best_seconds(pool, user_id).await?;
    repository::insert_bolt_score(pool, user_id, client_score_id, seconds, measured_at).await?;

    Ok(pb::RecordBoltScoreResponse {
        best_seconds: request.seconds.max(previous_best.unwrap_or(0)),
        is_personal_best: previous_best.is_none_or(|best| request.seconds > best),
    })
}

/// The caller's best pause, or `None` before they have taken one.
///
/// Read by `sessions::service::get_journey` as well as by the RPC above, so the
/// journey screen draws its BOLT card without a second round trip. The narrowing
/// onto the wire's unsigned field happens once, here, rather than differently at
/// each caller.
pub async fn best_seconds(pool: &PgPool, user_id: UserId) -> Result<Option<u32>, JourneyError> {
    repository::best_bolt_score(pool, user_id)
        .await?
        .map(|seconds| counted("best_bolt_seconds", seconds))
        .transpose()
}

/// The caller's whole BOLT history folded to [`BoltSnapshot`], or `None`
/// before they have taken the test.
///
/// Read by `sessions::service::practice_snapshot` on the same terms as
/// [`best_seconds`]: a sibling sub-feature reaches this history through the
/// service, never the repository.
pub async fn bolt_snapshot(
    pool: &PgPool,
    user_id: UserId,
) -> Result<Option<BoltSnapshot>, JourneyError> {
    let row = repository::bolt_aggregate(pool, user_id).await?;
    let (Some(best), Some(latest)) = (row.best, row.latest) else {
        return Ok(None);
    };

    Ok(Some(BoltSnapshot {
        best: counted("best_bolt_seconds", best)?,
        latest: counted("latest_bolt_seconds", latest)?,
        count: counted("bolt_count", row.count)?,
    }))
}
