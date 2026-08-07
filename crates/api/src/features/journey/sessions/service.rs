//! Business logic — validates what a client claims it did, and converts both
//! ways across the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::super::bolt;
use super::super::errors::JourneyError;
use super::super::wire::{counted, timestamp_from_proto, timestamp_to_proto, validated_offset};
use super::repository::{self, SessionRow};
use super::types::SessionCursor;
use crate::identity::UserId;
use crate::proto::breathe::v1 as pb;

/// How many sessions one call may carry.
///
/// A person breathing every waking hour for a month would not reach this, so it
/// bounds a client that has lost track of what it sent rather than a client
/// with a genuine backlog. The queue splits anything larger.
const MAX_SESSIONS_PER_BATCH: u32 = 200;

/// Twelve hours. Longer than any session the app can produce and short enough
/// that a stuck timer arrives as a rejection rather than as a person's totals.
const MAX_SESSION_DURATION_MS: u32 = 12 * 60 * 60 * 1000;

const MAX_CYCLES_PER_SESSION: u32 = 10_000;
const MAX_BREATHS_PER_SESSION: u32 = 100_000;

/// Matches the `CHECK` on `sessions.technique_slug`.
const MAX_SLUG_CHARS: usize = 64;

/// 2025-01-01T00:00:00Z, as an epoch second.
///
/// No session predates the first build of the app, and a row dated earlier is a
/// broken clock rather than a memory. Rejected rather than clamped: a silently
/// moved date would land in somebody's streak.
///
/// A timestamp rather than an RFC 3339 string so the check is a comparison
/// rather than a parse repeated for all two hundred records of a batch — and so
/// there is no unparseable case to invent a fallback for.
const EARLIEST_SESSION_TIMESTAMP: i64 = 1_735_689_600;

/// How far ahead of the server's clock a session may claim to have started.
///
/// Generous enough to absorb a device whose clock is a few hours out, tight
/// enough that a session dated next year cannot hold a streak open forever.
const MAX_CLOCK_SKEW_HOURS: i64 = 24;

/// How much history one page carries when the caller does not say.
///
/// The journey screen's strip: the last few weeks at a glance. A restore asks
/// for more and pages, which is what the default stopped being able to express
/// once the strip's bound was also the whole of the restore path.
const DEFAULT_SESSION_PAGE: usize = 50;

/// The largest page this server will assemble.
///
/// Sized for the restore rather than the strip. A person with three years of
/// daily practice recovers in three round trips, and the ceiling is what stops
/// one request folding an unbounded history into a single response body.
const MAX_SESSION_PAGE: usize = 500;

/// Stores a batch of finished sessions and says how many were new.
///
/// Idempotent on `(caller, client_session_id)`, which is what lets a client
/// re-send anything it is unsure about: `recorded` counts rows the database
/// really inserted and `already_known` accounts for the rest, so a retry is the
/// ordinary path rather than an error.
///
/// One impossible record fails the whole batch. A client that sent a session the
/// app cannot have produced has a bug, and quietly recording the other
/// ninety-nine would hide it behind a gap nobody can find.
pub async fn record_sessions(
    pool: &PgPool,
    user_id: UserId,
    submitted: Vec<pb::SessionRecord>,
) -> Result<pb::RecordSessionsResponse, JourneyError> {
    if submitted.is_empty() {
        return Err(JourneyError::Invalid("`sessions` is empty".to_owned()));
    }

    // Saturating rather than failing: a length past `u32::MAX` is past the batch
    // limit too, so it falls out of the same check with the same message.
    let submitted_count = u32::try_from(submitted.len()).unwrap_or(u32::MAX);
    if submitted_count > MAX_SESSIONS_PER_BATCH {
        return Err(JourneyError::Invalid(format!(
            "`sessions` carries more than {MAX_SESSIONS_PER_BATCH} records"
        )));
    }

    // Deduplicated before the insert rather than left to `ON CONFLICT`, so that
    // a batch repeating one id reports it as already known instead of as a row
    // the database quietly skipped.
    let mut seen = HashSet::with_capacity(submitted.len());
    let mut rows = Vec::with_capacity(submitted.len());
    for record in &submitted {
        let row = session_from_proto(record)?;
        if seen.insert(row.client_session_id) {
            rows.push(row);
        }
    }

    let inserted = repository::insert_sessions(pool, user_id, &rows).await?;
    let recorded: u32 = counted("recorded", inserted)?;

    Ok(pb::RecordSessionsResponse {
        recorded,
        already_known: submitted_count.saturating_sub(recorded),
    })
}

/// Forgets the sessions a person deleted on their device.
///
/// Ids the server does not hold are counted out rather than refused: the client
/// keeps a tombstone until this call succeeds, so it is entitled to send the
/// same id again and a second attempt must not fail the whole batch.
pub async fn delete_sessions(
    pool: &PgPool,
    user_id: UserId,
    submitted: Vec<String>,
) -> Result<pb::DeleteSessionsResponse, JourneyError> {
    if submitted.is_empty() {
        return Err(JourneyError::Invalid(
            "`client_session_ids` is empty".to_owned(),
        ));
    }

    if submitted.len() > MAX_SESSIONS_PER_BATCH as usize {
        return Err(JourneyError::Invalid(format!(
            "`client_session_ids` carries more than {MAX_SESSIONS_PER_BATCH} ids"
        )));
    }

    let mut ids = Vec::with_capacity(submitted.len());
    for raw in &submitted {
        ids.push(Uuid::parse_str(raw).map_err(|_| {
            JourneyError::Invalid(format!("`client_session_ids` entry `{raw}` is not a UUID"))
        })?);
    }

    let removed = repository::delete_sessions(pool, user_id, &ids).await?;

    Ok(pb::DeleteSessionsResponse {
        deleted: counted("deleted", removed)?,
    })
}

/// The caller's totals, streaks, best pause, and one page of their history.
///
/// Serves two callers with opposite needs from one RPC. The journey screen asks
/// for the default page and draws everything it needs from the answer. A device
/// restoring after a reinstall — where the Keychain identity survived and the
/// sessions file did not — asks for a large page and follows `next_page_token`
/// until none comes back, which is the only mechanism that returns the archive
/// rather than the strip.
///
/// The four reads are concurrent because none depends on any other and the
/// streak fold is the slowest of them, so serialising would put its latency in
/// front of three cheap queries on the screen a person opens to see their
/// numbers.
pub async fn get_journey(
    pool: &PgPool,
    user_id: UserId,
    request: pb::GetJourneyRequest,
) -> Result<pb::GetJourneyResponse, JourneyError> {
    let offset = validated_offset(request.utc_offset_minutes)?;
    let limit = match request.limit {
        None => DEFAULT_SESSION_PAGE,
        // Refused rather than rounded up to one, the same rule every other
        // number in this file follows: a page of one would walk a whole history
        // one record at a time, which is not what anybody asking for zero meant.
        Some(0) => {
            return Err(JourneyError::Invalid(
                "`limit` must be at least 1".to_owned(),
            ));
        }
        // A value past `usize` is past the ceiling too, so both land on the cap.
        Some(asked) => {
            usize::try_from(asked).map_or(MAX_SESSION_PAGE, |asked| asked.min(MAX_SESSION_PAGE))
        }
    };
    let cursor = request
        .page_token
        .as_deref()
        .map(SessionCursor::decode)
        .transpose()?;

    // One row past the page, so whether another page exists is the database's
    // answer rather than an inference — and so a history that ends exactly on a
    // page boundary does not cost a restore an extra empty round trip.
    let overfetch = i64::try_from(limit).unwrap_or(i64::MAX).saturating_add(1);
    let (totals, streaks, mut page, best_bolt) = tokio::try_join!(
        repository::totals(pool, user_id),
        repository::streaks(pool, user_id, offset),
        repository::recent_sessions(pool, user_id, overfetch, cursor),
        bolt::service::best_seconds(pool, user_id),
    )?;

    let has_more = page.len() > limit;
    page.truncate(limit);
    let next_page_token = page
        .last()
        .filter(|_| has_more)
        .map(|row| SessionCursor::from(row).encode());

    Ok(pb::GetJourneyResponse {
        totals: Some(pb::JourneyTotals {
            sessions: counted("sessions", totals.sessions)?,
            breaths: counted("breaths", totals.breaths)?,
            minutes: counted("minutes", totals.duration_ms / 60_000)?,
        }),
        current_streak_days: counted("current_streak_days", streaks.current)?,
        best_streak_days: counted("best_streak_days", streaks.best)?,
        recent_sessions: page
            .into_iter()
            .map(session_to_proto)
            .collect::<Result<Vec<_>, JourneyError>>()?,
        best_bolt_seconds: best_bolt,
        next_page_token,
    })
}

/// Narrows one submitted session to something the database accepts.
///
/// Every rejection is a value the wire format admits and no session can produce.
/// The whole batch fails rather than the offending record being dropped: a
/// client that sent one impossible session has a bug, and quietly recording the
/// other ninety-nine would hide it while leaving a gap nobody can find.
fn session_from_proto(record: &pb::SessionRecord) -> Result<SessionRow, JourneyError> {
    let client_session_id = Uuid::parse_str(&record.client_session_id).map_err(|_| {
        JourneyError::Invalid(format!(
            "`client_session_id` `{}` is not a UUID",
            record.client_session_id
        ))
    })?;

    let technique_slug = record.technique_slug.trim().to_owned();
    if technique_slug.is_empty() || technique_slug.chars().count() > MAX_SLUG_CHARS {
        return Err(JourneyError::Invalid(format!(
            "`technique_slug` must be between 1 and {MAX_SLUG_CHARS} characters"
        )));
    }

    let started_at = record
        .started_at
        .as_ref()
        .ok_or_else(|| JourneyError::Invalid("`started_at` is required".to_owned()))
        .and_then(|stamp| timestamp_from_proto(stamp, "started_at"))?;
    validate_started_at(started_at, Utc::now())?;

    Ok(SessionRow {
        client_session_id,
        technique_slug,
        started_at,
        duration_ms: bounded(record.duration_ms, MAX_SESSION_DURATION_MS, "duration_ms")?,
        cycles_completed: bounded(
            record.cycles_completed,
            MAX_CYCLES_PER_SESSION,
            "cycles_completed",
        )?,
        breath_count: bounded(record.breath_count, MAX_BREATHS_PER_SESSION, "breath_count")?,
        completed: record.completed,
    })
}

fn session_to_proto(row: SessionRow) -> Result<pb::SessionRecord, JourneyError> {
    Ok(pb::SessionRecord {
        client_session_id: row.client_session_id.to_string(),
        technique_slug: row.technique_slug,
        started_at: Some(timestamp_to_proto(row.started_at)),
        duration_ms: counted("duration_ms", row.duration_ms)?,
        cycles_completed: counted("cycles_completed", row.cycles_completed)?,
        breath_count: counted("breath_count", row.breath_count)?,
        completed: row.completed,
    })
}

fn bounded(value: u32, maximum: u32, field: &str) -> Result<i32, JourneyError> {
    if value > maximum {
        return Err(JourneyError::Invalid(format!(
            "`{field}` is larger than {maximum}"
        )));
    }

    i32::try_from(value).map_err(|_| JourneyError::Invalid(format!("`{field}` is out of range")))
}

/// Refuses a start time that cannot be a real session.
///
/// Both bounds guard streaks rather than storage: a session dated 1970 would sit
/// harmlessly in the table, but a session dated next year holds a current streak
/// open indefinitely and nothing later can close it.
fn validate_started_at(started_at: DateTime<Utc>, now: DateTime<Utc>) -> Result<(), JourneyError> {
    if started_at.timestamp() < EARLIEST_SESSION_TIMESTAMP {
        return Err(JourneyError::Invalid(
            "`started_at` predates the app".to_owned(),
        ));
    }

    if started_at > now + chrono::Duration::hours(MAX_CLOCK_SKEW_HOURS) {
        return Err(JourneyError::Invalid(
            "`started_at` is in the future".to_owned(),
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(started_at: DateTime<Utc>) -> pb::SessionRecord {
        pb::SessionRecord {
            client_session_id: Uuid::nil().to_string(),
            technique_slug: "box-breathing".to_owned(),
            started_at: Some(timestamp_to_proto(started_at)),
            duration_ms: 60_000,
            cycles_completed: 4,
            breath_count: 8,
            completed: true,
        }
    }

    /// A future-dated session would hold a current streak open forever, and
    /// nothing recorded later could close it. Real clock skew is absorbed;
    /// a date next year is not.
    #[test]
    fn a_future_session_is_refused_but_clock_skew_is_not() {
        let now = DateTime::from_timestamp(1_777_000_000, 0).expect("a representable instant");

        assert!(validate_started_at(now + chrono::Duration::hours(1), now).is_ok());
        assert!(matches!(
            validate_started_at(now + chrono::Duration::days(30), now),
            Err(JourneyError::Invalid(_))
        ));
        assert!(matches!(
            validate_started_at(
                DateTime::from_timestamp(0, 0).expect("the epoch is representable"),
                now
            ),
            Err(JourneyError::Invalid(_))
        ));
    }

    /// A session the app cannot have produced fails the batch rather than being
    /// stored — an hour-long "cycle count" of four billion would otherwise sit
    /// in somebody's totals forever.
    #[test]
    fn an_impossible_session_fails_the_batch() {
        let now = Utc::now();

        let mut too_long = record(now);
        too_long.duration_ms = MAX_SESSION_DURATION_MS + 1;
        assert!(matches!(
            session_from_proto(&too_long),
            Err(JourneyError::Invalid(_))
        ));

        let mut no_slug = record(now);
        no_slug.technique_slug = "   ".to_owned();
        assert!(matches!(
            session_from_proto(&no_slug),
            Err(JourneyError::Invalid(_))
        ));

        let mut bad_id = record(now);
        bad_id.client_session_id = "not-a-uuid".to_owned();
        assert!(matches!(
            session_from_proto(&bad_id),
            Err(JourneyError::Invalid(_))
        ));

        assert!(session_from_proto(&record(now)).is_ok());
    }
}
