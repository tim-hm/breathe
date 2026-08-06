//! Business logic — validates what a client claims it did, and converts both
//! ways across the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`), never `Arc<AppState>`, and
//! contains zero raw queries: SQL lives in `super::repository`.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::JourneyError;
use super::repository::{self, LeaderboardRow, SessionRow};
use super::types::{LeaderboardBoard, LeaderboardScope};
use crate::features::profile::repository as profile_repository;
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

/// Matches the `CHECK` on `bolt_scores.seconds`.
const MAX_BOLT_SECONDS: u32 = 600;

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

/// UTC offsets in use run from -12:00 to +14:00. Anything outside is not a time
/// zone.
const MIN_UTC_OFFSET_MINUTES: i32 = -12 * 60;
const MAX_UTC_OFFSET_MINUTES: i32 = 14 * 60;

/// How much history the journey screen's strip carries.
///
/// A bound rather than a page: this is the last few weeks at a glance, and a
/// person who wants their whole history has it on the device that recorded it.
const RECENT_SESSION_LIMIT: i64 = 50;

/// How many named entries a board returns.
const LEADERBOARD_LIMIT: i64 = 20;

pub async fn record_sessions(
    pool: &PgPool,
    user_id: Uuid,
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

    let recorded = u32::try_from(repository::insert_sessions(pool, user_id, &rows).await?)
        .unwrap_or(MAX_SESSIONS_PER_BATCH);

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
    user_id: Uuid,
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

    let deleted = u32::try_from(repository::delete_sessions(pool, user_id, &ids).await?)
        .unwrap_or(MAX_SESSIONS_PER_BATCH);

    Ok(pb::DeleteSessionsResponse { deleted })
}

pub async fn get_journey(
    pool: &PgPool,
    user_id: Uuid,
    utc_offset_minutes: i32,
) -> Result<pb::GetJourneyResponse, JourneyError> {
    let offset = validated_offset(utc_offset_minutes)?;

    let totals = repository::totals(pool, user_id).await?;
    let streaks = repository::streaks(pool, user_id, offset).await?;
    let recent = repository::recent_sessions(pool, user_id, RECENT_SESSION_LIMIT).await?;
    let best_bolt = repository::best_bolt_score(pool, user_id).await?;

    Ok(pb::GetJourneyResponse {
        totals: Some(pb::JourneyTotals {
            sessions: u32::try_from(totals.sessions).unwrap_or(u32::MAX),
            breaths: u64::try_from(totals.breaths).unwrap_or(0),
            minutes: u64::try_from(totals.duration_ms / 60_000).unwrap_or(0),
        }),
        current_streak_days: u32::try_from(streaks.current).unwrap_or(0),
        best_streak_days: u32::try_from(streaks.best).unwrap_or(0),
        recent_sessions: recent.into_iter().map(session_to_proto).collect(),
        best_bolt_seconds: best_bolt.and_then(|seconds| u32::try_from(seconds).ok()),
    })
}

pub async fn record_bolt_score(
    pool: &PgPool,
    user_id: Uuid,
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
    let previous_best = repository::best_bolt_score(pool, user_id).await?;
    repository::insert_bolt_score(pool, user_id, client_score_id, seconds, measured_at).await?;

    let is_personal_best = previous_best.is_none_or(|best| seconds > best);

    Ok(pb::RecordBoltScoreResponse {
        best_seconds: request.seconds.max(
            previous_best
                .and_then(|best| u32::try_from(best).ok())
                .unwrap_or(0),
        ),
        is_personal_best,
    })
}

pub async fn get_leaderboard(
    pool: &PgPool,
    user_id: Uuid,
    request: pb::GetLeaderboardRequest,
) -> Result<pb::GetLeaderboardResponse, JourneyError> {
    let board = board_from_proto(request.board)?;
    let scope = scope_from_proto(request.scope)?;

    let band = match scope {
        LeaderboardScope::Global => None,
        LeaderboardScope::AgeBand => Some(
            profile_repository::find_birth_year_band(pool, user_id)
                .await?
                .ok_or(JourneyError::AgeBandUnset)?,
        ),
    };

    let rows = match board {
        LeaderboardBoard::Streak => {
            let offset = validated_offset(request.utc_offset_minutes)?;
            repository::streak_board(pool, user_id, band, LEADERBOARD_LIMIT, offset).await?
        }
        LeaderboardBoard::Minutes30d => {
            repository::minutes_board(pool, user_id, band, LEADERBOARD_LIMIT).await?
        }
        LeaderboardBoard::Bolt => {
            repository::bolt_board(pool, user_id, band, LEADERBOARD_LIMIT).await?
        }
    };

    Ok(to_leaderboard_response(user_id, rows))
}

/// Splits the one board query into the part everybody sees and the part only the
/// caller does.
///
/// The caller's own row arrives alongside the leading entries, and it may or may
/// not be one of them — somebody in the top twenty appears once, in both roles.
fn to_leaderboard_response(user_id: Uuid, rows: Vec<LeaderboardRow>) -> pb::GetLeaderboardResponse {
    let caller =
        rows.iter()
            .find(|row| row.user_id == user_id)
            .map(|row| pb::LeaderboardStanding {
                rank: u32::try_from(row.rank).ok(),
                value: u32::try_from(row.value).unwrap_or(0),
                listed: row.display_name.is_some(),
            });

    let entries = rows
        .into_iter()
        .filter(|row| row.on_board)
        .filter_map(|row| {
            Some(pb::LeaderboardEntry {
                rank: u32::try_from(row.rank).ok()?,
                display_name: row.display_name?,
                value: u32::try_from(row.value).unwrap_or(0),
            })
        })
        .collect();

    pb::GetLeaderboardResponse {
        entries,
        // Present even when the caller has nothing to rank, so the client can
        // tell "no score yet" from "no answer" without a second field.
        caller: Some(caller.unwrap_or(pb::LeaderboardStanding {
            rank: None,
            value: 0,
            listed: false,
        })),
    }
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

fn session_to_proto(row: SessionRow) -> pb::SessionRecord {
    pb::SessionRecord {
        client_session_id: row.client_session_id.to_string(),
        technique_slug: row.technique_slug,
        started_at: Some(timestamp_to_proto(row.started_at)),
        duration_ms: u32::try_from(row.duration_ms).unwrap_or(0),
        cycles_completed: u32::try_from(row.cycles_completed).unwrap_or(0),
        breath_count: u32::try_from(row.breath_count).unwrap_or(0),
        completed: row.completed,
    }
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

fn validated_offset(minutes: i32) -> Result<i32, JourneyError> {
    if (MIN_UTC_OFFSET_MINUTES..=MAX_UTC_OFFSET_MINUTES).contains(&minutes) {
        return Ok(minutes);
    }

    Err(JourneyError::Invalid(format!(
        "`utc_offset_minutes` must be between {MIN_UTC_OFFSET_MINUTES} and {MAX_UTC_OFFSET_MINUTES}"
    )))
}

/// `google.protobuf.Timestamp` admits values no instant can hold — a negative
/// nanosecond count, a second count past the end of the calendar — so the
/// conversion is fallible and says which field failed.
fn timestamp_from_proto(
    stamp: &prost_types::Timestamp,
    field: &str,
) -> Result<DateTime<Utc>, JourneyError> {
    u32::try_from(stamp.nanos)
        .ok()
        .and_then(|nanos| DateTime::from_timestamp(stamp.seconds, nanos))
        .ok_or_else(|| JourneyError::Invalid(format!("`{field}` is not a valid timestamp")))
}

fn timestamp_to_proto(instant: DateTime<Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: instant.timestamp(),
        // A leap second reports more than a billion subsecond nanoseconds, which
        // the proto type cannot carry; clamping loses at most that one second.
        nanos: i32::try_from(instant.timestamp_subsec_nanos()).unwrap_or(999_999_999),
    }
}

fn board_from_proto(raw: i32) -> Result<LeaderboardBoard, JourneyError> {
    match pb::LeaderboardBoard::try_from(raw) {
        Ok(pb::LeaderboardBoard::Streak) => Ok(LeaderboardBoard::Streak),
        Ok(pb::LeaderboardBoard::Minutes30d) => Ok(LeaderboardBoard::Minutes30d),
        Ok(pb::LeaderboardBoard::Bolt) => Ok(LeaderboardBoard::Bolt),
        Ok(pb::LeaderboardBoard::Unspecified) | Err(_) => Err(JourneyError::Invalid(format!(
            "`{raw}` is not a board this server knows"
        ))),
    }
}

fn scope_from_proto(raw: i32) -> Result<LeaderboardScope, JourneyError> {
    match pb::LeaderboardScope::try_from(raw) {
        Ok(pb::LeaderboardScope::Global) => Ok(LeaderboardScope::Global),
        Ok(pb::LeaderboardScope::AgeBand) => Ok(LeaderboardScope::AgeBand),
        Ok(pb::LeaderboardScope::Unspecified) | Err(_) => Err(JourneyError::Invalid(format!(
            "`{raw}` is not a scope this server knows"
        ))),
    }
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

    /// The round trip a recent session makes on the way back out. Sub-second
    /// precision matters because a session at 23:59:59.9 local is the difference
    /// between a streak that held and one that paused.
    #[test]
    fn a_timestamp_survives_the_round_trip() {
        let instant =
            DateTime::from_timestamp(1_777_000_000, 123_456_789).expect("a representable instant");

        assert_eq!(
            timestamp_from_proto(&timestamp_to_proto(instant), "started_at")
                .expect("a converted timestamp is valid"),
            instant
        );
    }

    /// A negative nanosecond count is representable on the wire and is not an
    /// instant. Decoding it as one would put a session at an arbitrary moment.
    #[test]
    fn an_impossible_timestamp_fails_rather_than_being_guessed_at() {
        let malformed = prost_types::Timestamp {
            seconds: 1_777_000_000,
            nanos: -1,
        };

        assert!(matches!(
            timestamp_from_proto(&malformed, "started_at"),
            Err(JourneyError::Invalid(_))
        ));
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

    /// Every board and scope the proto can carry has to be either a real case or
    /// a rejection — a zero value silently becoming STREAK would answer a
    /// question nobody asked.
    #[test]
    fn an_unspecified_board_or_scope_is_refused() {
        assert!(matches!(
            board_from_proto(pb::LeaderboardBoard::Unspecified as i32),
            Err(JourneyError::Invalid(_))
        ));
        assert!(matches!(
            scope_from_proto(pb::LeaderboardScope::Unspecified as i32),
            Err(JourneyError::Invalid(_))
        ));
        assert!(board_from_proto(pb::LeaderboardBoard::Bolt as i32).is_ok());
        assert!(scope_from_proto(pb::LeaderboardScope::AgeBand as i32).is_ok());
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

    /// The offsets that exist run from -12:00 to +14:00. Anything else is a
    /// client bug, and accepting it would silently shift somebody's calendar
    /// days.
    #[test]
    fn only_real_utc_offsets_are_accepted() {
        for minutes in [MIN_UTC_OFFSET_MINUTES, 0, 60, MAX_UTC_OFFSET_MINUTES] {
            assert!(validated_offset(minutes).is_ok());
        }
        for minutes in [MIN_UTC_OFFSET_MINUTES - 1, MAX_UTC_OFFSET_MINUTES + 1] {
            assert!(matches!(
                validated_offset(minutes),
                Err(JourneyError::Invalid(_))
            ));
        }
    }
}
