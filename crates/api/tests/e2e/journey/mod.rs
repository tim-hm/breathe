//! `JourneyService` over the wire the iOS client uses.
//!
//! Split the ways the feature is: the history a person records, the controlled
//! pauses they measure, the boards that rank everyone — and the practice
//! snapshot derived from the first two. The fixtures sit here rather than in
//! each file because all of them build sessions and identities the same way,
//! and four copies of `session()` would be four places for a test's arithmetic
//! to drift.

use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;
use chrono::{DateTime, Duration, Utc};

use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web_with};

mod bolt;
mod leaderboard;
mod sessions;
mod snapshot;

const RECORD_SESSIONS: &str = "/breathe.v1.JourneyService/RecordSessions";
const DELETE_SESSIONS: &str = "/breathe.v1.JourneyService/DeleteSessions";
const GET_JOURNEY: &str = "/breathe.v1.JourneyService/GetJourney";
const RECORD_BOLT_SCORE: &str = "/breathe.v1.JourneyService/RecordBoltScore";
const GET_LEADERBOARD: &str = "/breathe.v1.JourneyService/GetLeaderboard";
const UPDATE_PROFILE: &str = "/breathe.v1.ProfileService/UpdateProfile";

/// Stable identities, so a failing test leaves rows someone can go and look at.
const ADA: &str = "6a1f0000-0000-4000-8000-000000000001";
const BEA: &str = "6a1f0000-0000-4000-8000-000000000002";
const CAL: &str = "6a1f0000-0000-4000-8000-000000000003";

fn session(id: &str, started_at: DateTime<Utc>) -> pb::SessionRecord {
    minutes_session(id, started_at, 2)
}

fn minutes_session(id: &str, started_at: DateTime<Utc>, minutes: u32) -> pb::SessionRecord {
    pb::SessionRecord {
        client_session_id: id.to_owned(),
        technique_slug: "box-breathing".to_owned(),
        started_at: Some(prost_timestamp(started_at)),
        duration_ms: minutes * 60_000,
        cycles_completed: 4,
        breath_count: 8,
        completed: true,
    }
}

fn prost_timestamp(instant: DateTime<Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: instant.timestamp(),
        nanos: 0,
    }
}

fn hours_ago(hours: i64) -> DateTime<Utc> {
    Utc::now() - Duration::hours(hours)
}

/// Exactly `days` × 24 hours ago, which in a fixed offset is the same clock time
/// that many local days back — so a test can name a local day without knowing
/// what time it is when it runs.
fn days_ago(days: i64) -> DateTime<Utc> {
    Utc::now() - Duration::days(days)
}

async fn record(
    db: &TestDatabase,
    user: &str,
    sessions: Vec<pb::SessionRecord>,
) -> GrpcWebResponse<pb::RecordSessionsResponse> {
    call_grpc_web_with(
        db.app(),
        RECORD_SESSIONS,
        &pb::RecordSessionsRequest { sessions },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn delete(
    db: &TestDatabase,
    user: &str,
    client_session_ids: Vec<String>,
) -> GrpcWebResponse<pb::DeleteSessionsResponse> {
    call_grpc_web_with(
        db.app(),
        DELETE_SESSIONS,
        &pb::DeleteSessionsRequest { client_session_ids },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn journey(
    db: &TestDatabase,
    user: &str,
    utc_offset_minutes: i32,
) -> GrpcWebResponse<pb::GetJourneyResponse> {
    journey_page(db, user, utc_offset_minutes, None, None).await
}

async fn journey_page(
    db: &TestDatabase,
    user: &str,
    utc_offset_minutes: i32,
    limit: Option<u32>,
    page_token: Option<String>,
) -> GrpcWebResponse<pb::GetJourneyResponse> {
    call_grpc_web_with(
        db.app(),
        GET_JOURNEY,
        &pb::GetJourneyRequest {
            utc_offset_minutes,
            limit,
            page_token,
        },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

/// Derives the score id from the measurement, so it is stable across runs and a
/// failing test leaves a row someone can go and look at. Distinct scores get
/// distinct ids, which is all any test here needs; `bolt_with` is for the ones
/// that deliberately resend an id or place a measurement in time.
async fn bolt_score(
    db: &TestDatabase,
    user: &str,
    seconds: u32,
) -> GrpcWebResponse<pb::RecordBoltScoreResponse> {
    bolt_with(
        db,
        user,
        &format!("aaaaaaaa-0000-4000-8000-{seconds:012}"),
        seconds,
        None,
    )
    .await
}

async fn bolt_with(
    db: &TestDatabase,
    user: &str,
    client_score_id: &str,
    seconds: u32,
    measured_at: Option<DateTime<Utc>>,
) -> GrpcWebResponse<pb::RecordBoltScoreResponse> {
    call_grpc_web_with(
        db.app(),
        RECORD_BOLT_SCORE,
        &pb::RecordBoltScoreRequest {
            client_score_id: client_score_id.to_owned(),
            seconds,
            measured_at: measured_at.map(prost_timestamp),
        },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn board(
    db: &TestDatabase,
    user: &str,
    board: pb::LeaderboardBoard,
    scope: pb::LeaderboardScope,
) -> GrpcWebResponse<pb::GetLeaderboardResponse> {
    call_grpc_web_with(
        db.app(),
        GET_LEADERBOARD,
        &pb::GetLeaderboardRequest {
            board: board as i32,
            scope: scope as i32,
            utc_offset_minutes: 0,
        },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn name(db: &TestDatabase, user: &str, display_name: &str) {
    profile(db, user, display_name, pb::BirthYearBand::Unspecified).await;
}

async fn profile(db: &TestDatabase, user: &str, display_name: &str, band: pb::BirthYearBand) {
    let response: GrpcWebResponse<pb::UpdateProfileResponse> = call_grpc_web_with(
        db.app(),
        UPDATE_PROFILE,
        &pb::UpdateProfileRequest {
            profile: Some(pb::Profile {
                display_name: display_name.to_owned(),
                birth_year_band: band as i32,
                ..pb::Profile::default()
            }),
        },
        &[(USER_ID_HEADER, user)],
    )
    .await;

    response.into_ok();
}
