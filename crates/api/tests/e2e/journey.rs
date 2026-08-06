//! `JourneyService` over the wire the iOS client uses.
//!
//! Almost everything here is about arithmetic that no compiler checks: a streak
//! is a fold over calendar days in a time zone the server does not store, and a
//! leaderboard is a ranking that has to count people it must not name.

use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;
use chrono::{DateTime, Duration, TimeZone, Utc};

use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web_with};

const RECORD_SESSIONS: &str = "/breathe.v1.JourneyService/RecordSessions";
const GET_JOURNEY: &str = "/breathe.v1.JourneyService/GetJourney";
const RECORD_BOLT_SCORE: &str = "/breathe.v1.JourneyService/RecordBoltScore";
const GET_LEADERBOARD: &str = "/breathe.v1.JourneyService/GetLeaderboard";
const UPDATE_PROFILE: &str = "/breathe.v1.ProfileService/UpdateProfile";

/// Stable identities, so a failing test leaves rows someone can go and look at.
const ADA: &str = "6a1f0000-0000-4000-8000-000000000001";
const BEA: &str = "6a1f0000-0000-4000-8000-000000000002";
const CAL: &str = "6a1f0000-0000-4000-8000-000000000003";

/// The contract that lets a client re-send anything it is unsure about: the
/// same batch twice stores one copy and says so. Without it, a request that
/// succeeded but whose response was lost would double every total on retry.
#[tokio::test]
async fn a_resent_batch_records_nothing_and_says_so() {
    let db = TestDatabase::create("journey_idempotent").await;
    let batch = vec![
        session("11111111-0000-4000-8000-000000000001", hours_ago(1)),
        session("11111111-0000-4000-8000-000000000002", hours_ago(2)),
        session("11111111-0000-4000-8000-000000000003", hours_ago(3)),
    ];

    let first = record(&db, ADA, batch.clone()).await.into_ok();
    assert_eq!((first.recorded, first.already_known), (3, 0));

    let second = record(&db, ADA, batch.clone()).await.into_ok();
    assert_eq!((second.recorded, second.already_known), (0, 3));

    // A batch that repeats an id within itself is the same claim twice, and has
    // to be counted that way rather than silently collapsing to one session.
    let repeated = record(
        &db,
        ADA,
        vec![
            session("11111111-0000-4000-8000-000000000004", hours_ago(4)),
            session("11111111-0000-4000-8000-000000000004", hours_ago(4)),
        ],
    )
    .await
    .into_ok();
    assert_eq!((repeated.recorded, repeated.already_known), (1, 1));

    let journey = journey(&db, ADA, 0).await.into_ok();
    let totals = journey.totals.expect("a journey carries totals");
    assert_eq!(totals.sessions, 4);
}

/// The whole reason the offset travels per request. These two sessions are two
/// hours apart across a UTC midnight: read in UTC they are consecutive days,
/// read two hours west they are one late evening. Same rows, different streak,
/// and only the client knows which is right.
#[tokio::test]
async fn a_local_day_is_the_callers_day_not_utc() {
    let db = TestDatabase::create("journey_offset_boundary").await;

    let late = utc_at(days_ago(10), 23, 0);
    record(
        &db,
        ADA,
        vec![
            session("22222222-0000-4000-8000-000000000001", late),
            session(
                "22222222-0000-4000-8000-000000000002",
                late + Duration::hours(2),
            ),
        ],
    )
    .await
    .into_ok();

    assert_eq!(journey(&db, ADA, 0).await.into_ok().best_streak_days, 2);
    assert_eq!(
        journey(&db, ADA, -120).await.into_ok().best_streak_days,
        1,
        "two hours west, 01:00 UTC is still the previous evening"
    );
}

/// A streak is not broken until a whole local day has passed with no session,
/// so somebody who has not breathed yet this morning has not lost anything. The
/// day before that is a pause — and the best streak keeps the number, which is
/// the thing left to celebrate.
#[tokio::test]
async fn a_streak_survives_until_a_whole_day_has_passed() {
    let db = TestDatabase::create("journey_streak_yesterday").await;

    record(
        &db,
        ADA,
        vec![session("33333333-0000-4000-8000-000000000001", days_ago(1))],
    )
    .await
    .into_ok();
    let yesterday_only = journey(&db, ADA, 0).await.into_ok();
    assert_eq!(yesterday_only.current_streak_days, 1);

    record(
        &db,
        BEA,
        vec![session("33333333-0000-4000-8000-000000000002", days_ago(2))],
    )
    .await
    .into_ok();
    let paused = journey(&db, BEA, 0).await.into_ok();
    assert_eq!(paused.current_streak_days, 0);
    assert_eq!(
        paused.best_streak_days, 1,
        "the run itself is not forgotten"
    );

    record(
        &db,
        ADA,
        vec![session(
            "33333333-0000-4000-8000-000000000003",
            hours_ago(1),
        )],
    )
    .await
    .into_ok();
    assert_eq!(journey(&db, ADA, 0).await.into_ok().current_streak_days, 2);
}

/// One person's sessions must never reach another's journey. There is no id in
/// the request message, so the only way this breaks is a query that forgot its
/// `WHERE user_id`.
#[tokio::test]
async fn journeys_are_scoped_to_the_calling_identity() {
    let db = TestDatabase::create("journey_scoping").await;

    record(
        &db,
        ADA,
        vec![session(
            "44444444-0000-4000-8000-000000000001",
            hours_ago(1),
        )],
    )
    .await
    .into_ok();

    let theirs = journey(&db, BEA, 0).await.into_ok();
    let totals = theirs.totals.expect("a journey carries totals");

    assert_eq!((totals.sessions, totals.breaths, totals.minutes), (0, 0, 0));
    assert_eq!(theirs.current_streak_days, 0);
    assert!(theirs.recent_sessions.is_empty());
    assert_eq!(theirs.best_bolt_seconds, None);
}

/// The personal best is the server's answer rather than the client's, because a
/// client that was offline for three tests does not hold the history to compare
/// against. A lower score afterwards must not overwrite it.
#[tokio::test]
async fn a_bolt_score_is_a_personal_best_only_when_it_beats_the_history() {
    let db = TestDatabase::create("journey_bolt_best").await;

    let first = bolt(&db, ADA, 20).await.into_ok();
    assert_eq!((first.best_seconds, first.is_personal_best), (20, true));

    let lower = bolt(&db, ADA, 15).await.into_ok();
    assert_eq!((lower.best_seconds, lower.is_personal_best), (20, false));

    let higher = bolt(&db, ADA, 25).await.into_ok();
    assert_eq!((higher.best_seconds, higher.is_personal_best), (25, true));

    assert_eq!(
        journey(&db, ADA, 0).await.into_ok().best_bolt_seconds,
        Some(25),
        "the journey screen draws its BOLT card without a second round trip"
    );

    let nonsense = bolt(&db, ADA, 20_000).await;
    assert_eq!(nonsense.status, tonic::Code::InvalidArgument as i32);
}

/// Pause scores drain through the same opportunistic queue as sessions, so a
/// resend has to be as free here as it is there. Without the client-minted id
/// the client's own ledger would be the only thing preventing a duplicate, and
/// duplicates hide behind `max(seconds)` on every board.
#[tokio::test]
async fn a_resent_bolt_score_does_not_become_a_second_one() {
    let db = TestDatabase::create("journey_bolt_idempotent").await;
    let id = "99999999-0000-4000-8000-000000000001";

    let first = bolt_with(&db, ADA, id, 24).await.into_ok();
    assert_eq!((first.best_seconds, first.is_personal_best), (24, true));

    let resent = bolt_with(&db, ADA, id, 24).await.into_ok();
    assert_eq!(resent.best_seconds, 24);
    assert!(
        !resent.is_personal_best,
        "the score is already on record, so it cannot beat it"
    );
    assert_eq!(count_bolt_scores(&db).await, 1);

    // Another person may hold the same client id without colliding: the key is
    // the pair, not the id alone.
    bolt_with(&db, BEA, id, 30).await.into_ok();
    assert_eq!(count_bolt_scores(&db).await, 2);

    let malformed = bolt_with(&db, ADA, "not-a-uuid", 20).await;
    assert_eq!(malformed.status, tonic::Code::InvalidArgument as i32);
}

/// The opt-in, from both sides. Somebody with no display name is counted in the
/// ranking and named to nobody — they still see exactly where they stand, which
/// is what makes the boards worth opting into rather than a wall someone has to
/// climb first.
#[tokio::test]
async fn a_board_ranks_everyone_and_names_only_the_opted_in() {
    let db = TestDatabase::create("journey_board_visibility").await;

    name(&db, ADA, "Ada").await;
    record(
        &db,
        ADA,
        vec![session(
            "55555555-0000-4000-8000-000000000001",
            hours_ago(1),
        )],
    )
    .await
    .into_ok();

    record(
        &db,
        BEA,
        vec![
            session("55555555-0000-4000-8000-000000000002", hours_ago(1)),
            session("55555555-0000-4000-8000-000000000003", days_ago(1)),
            session("55555555-0000-4000-8000-000000000004", days_ago(2)),
        ],
    )
    .await
    .into_ok();

    let anonymous = board(
        &db,
        BEA,
        pb::LeaderboardBoard::Streak,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();

    assert_eq!(
        anonymous
            .entries
            .iter()
            .map(|entry| entry.display_name.as_str())
            .collect::<Vec<_>>(),
        vec!["Ada"],
        "the leader is unnamed, so the board shows only the person below them"
    );
    let standing = anonymous.caller.expect("a standing is always returned");
    assert_eq!((standing.rank, standing.value), (Some(1), 3));
    assert!(!standing.listed);

    let named = board(
        &db,
        ADA,
        pb::LeaderboardBoard::Streak,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();
    let standing = named.caller.expect("a standing is always returned");
    assert_eq!((standing.rank, standing.value), (Some(2), 1));
    assert!(standing.listed, "a name is the whole of the opt-in");
    assert_eq!(
        named.entries.first().map(|entry| entry.rank),
        Some(2),
        "the rank counts the unnamed leader, so the board starts at two"
    );
}

/// The age-band scope draws a different population from the same rows, and asks
/// for something the caller may not have said — which is a precondition rather
/// than a malformed request, so the client can offer the question instead of
/// correcting a field.
#[tokio::test]
async fn the_age_band_scope_compares_like_with_like() {
    let db = TestDatabase::create("journey_board_age_band").await;

    profile(&db, ADA, "Ada", pb::BirthYearBand::Born1980s).await;
    profile(&db, BEA, "Bea", pb::BirthYearBand::Born1990s).await;
    profile(&db, CAL, "", pb::BirthYearBand::Born1980s).await;

    record(
        &db,
        ADA,
        vec![session(
            "66666666-0000-4000-8000-000000000001",
            hours_ago(1),
        )],
    )
    .await
    .into_ok();
    record(
        &db,
        BEA,
        vec![
            session("66666666-0000-4000-8000-000000000002", hours_ago(1)),
            session("66666666-0000-4000-8000-000000000003", days_ago(1)),
            session("66666666-0000-4000-8000-000000000004", days_ago(2)),
        ],
    )
    .await
    .into_ok();
    record(
        &db,
        CAL,
        vec![
            session("66666666-0000-4000-8000-000000000005", hours_ago(1)),
            session("66666666-0000-4000-8000-000000000006", days_ago(1)),
        ],
    )
    .await
    .into_ok();

    let global = board(
        &db,
        CAL,
        pb::LeaderboardBoard::Streak,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();
    assert_eq!(
        global
            .entries
            .iter()
            .map(|entry| (entry.display_name.as_str(), entry.rank))
            .collect::<Vec<_>>(),
        vec![("Bea", 1), ("Ada", 3)]
    );
    assert_eq!(
        global.caller.expect("a standing").rank,
        Some(2),
        "two days is second of three globally"
    );

    let banded = board(
        &db,
        CAL,
        pb::LeaderboardBoard::Streak,
        pb::LeaderboardScope::AgeBand,
    )
    .await
    .into_ok();
    assert_eq!(
        banded
            .entries
            .iter()
            .map(|entry| entry.display_name.as_str())
            .collect::<Vec<_>>(),
        vec!["Ada"],
        "Bea is in another decade and drops out of the population entirely"
    );
    assert_eq!(banded.caller.expect("a standing").rank, Some(1));

    let unbanded: GrpcWebResponse<pb::GetLeaderboardResponse> = call_grpc_web_with(
        db.app(),
        GET_LEADERBOARD,
        &pb::GetLeaderboardRequest {
            board: pb::LeaderboardBoard::Streak as i32,
            scope: pb::LeaderboardScope::AgeBand as i32,
            utc_offset_minutes: 0,
        },
        &[(USER_ID_HEADER, "6a1f0000-0000-4000-8000-000000000009")],
    )
    .await;
    assert_eq!(unbanded.status, tonic::Code::FailedPrecondition as i32);
}

/// The other two boards, which share the streak board's ranking shape and differ
/// only in what they measure. Worth pinning because each has its own `scored`
/// query: the minutes board floors at a whole minute, and the BOLT board ranks a
/// best rather than a total.
#[tokio::test]
async fn the_minutes_and_bolt_boards_measure_their_own_thing() {
    let db = TestDatabase::create("journey_board_measures").await;

    name(&db, ADA, "Ada").await;
    name(&db, BEA, "Bea").await;

    // Ada breathes twice for two minutes; Bea once for five.
    record(
        &db,
        ADA,
        vec![
            minutes_session("77777777-0000-4000-8000-000000000001", hours_ago(1), 2),
            minutes_session("77777777-0000-4000-8000-000000000002", days_ago(1), 2),
        ],
    )
    .await
    .into_ok();
    record(
        &db,
        BEA,
        vec![minutes_session(
            "77777777-0000-4000-8000-000000000003",
            hours_ago(1),
            5,
        )],
    )
    .await
    .into_ok();

    let minutes = board(
        &db,
        ADA,
        pb::LeaderboardBoard::Minutes30d,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();
    assert_eq!(
        minutes
            .entries
            .iter()
            .map(|entry| (entry.display_name.as_str(), entry.value))
            .collect::<Vec<_>>(),
        vec![("Bea", 5), ("Ada", 4)]
    );

    bolt(&db, ADA, 30).await.into_ok();
    bolt(&db, BEA, 18).await.into_ok();

    let scores = board(
        &db,
        BEA,
        pb::LeaderboardBoard::Bolt,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();
    assert_eq!(
        scores
            .entries
            .iter()
            .map(|entry| (entry.display_name.as_str(), entry.value))
            .collect::<Vec<_>>(),
        vec![("Ada", 30), ("Bea", 18)]
    );
    assert_eq!(scores.caller.expect("a standing").rank, Some(2));
}

/// The identity rules, on the one service where a missing header would
/// otherwise attribute somebody's sessions to nobody at all.
#[tokio::test]
async fn a_journey_call_without_an_identity_is_unauthenticated() {
    let db = TestDatabase::create("journey_unauthenticated").await;

    let anonymous: GrpcWebResponse<pb::GetJourneyResponse> = call_grpc_web_with(
        db.app(),
        GET_JOURNEY,
        &pb::GetJourneyRequest {
            utc_offset_minutes: 0,
        },
        &[],
    )
    .await;

    assert_eq!(anonymous.status, tonic::Code::Unauthenticated as i32);
}

/// A batch of garbage fails whole rather than being partly stored: a client that
/// sent one impossible session has a bug, and recording the rest would hide it
/// behind a gap nobody can find.
#[tokio::test]
async fn an_impossible_session_fails_the_whole_batch() {
    let db = TestDatabase::create("journey_invalid_batch").await;

    let mut future = session("88888888-0000-4000-8000-000000000001", hours_ago(1));
    future.started_at = Some(prost_timestamp(Utc::now() + Duration::days(400)));

    let response = record(
        &db,
        ADA,
        vec![
            session("88888888-0000-4000-8000-000000000002", hours_ago(1)),
            future,
        ],
    )
    .await;

    assert_eq!(response.status, tonic::Code::InvalidArgument as i32);
    assert_eq!(
        journey(&db, ADA, 0)
            .await
            .into_ok()
            .totals
            .expect("a journey carries totals")
            .sessions,
        0,
        "nothing in the batch was stored"
    );

    let empty = record(&db, ADA, vec![]).await;
    assert_eq!(empty.status, tonic::Code::InvalidArgument as i32);
}

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

/// A fixed instant on the same date as `reference`, in UTC. Used to place a
/// session either side of a UTC midnight deterministically.
fn utc_at(reference: DateTime<Utc>, hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.from_utc_datetime(
        &reference
            .date_naive()
            .and_hms_opt(hour, minute, 0)
            .expect("a valid time of day"),
    )
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

async fn journey(
    db: &TestDatabase,
    user: &str,
    utc_offset_minutes: i32,
) -> GrpcWebResponse<pb::GetJourneyResponse> {
    call_grpc_web_with(
        db.app(),
        GET_JOURNEY,
        &pb::GetJourneyRequest { utc_offset_minutes },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

/// Derives the score id from the measurement, so it is stable across runs and a
/// failing test leaves a row someone can go and look at. Distinct scores get
/// distinct ids, which is all any test here needs; `bolt_with` is for the one
/// that deliberately resends the same id.
async fn bolt(
    db: &TestDatabase,
    user: &str,
    seconds: u32,
) -> GrpcWebResponse<pb::RecordBoltScoreResponse> {
    bolt_with(
        db,
        user,
        &format!("aaaaaaaa-0000-4000-8000-{seconds:012}"),
        seconds,
    )
    .await
}

async fn bolt_with(
    db: &TestDatabase,
    user: &str,
    client_score_id: &str,
    seconds: u32,
) -> GrpcWebResponse<pb::RecordBoltScoreResponse> {
    call_grpc_web_with(
        db.app(),
        RECORD_BOLT_SCORE,
        &pb::RecordBoltScoreRequest {
            client_score_id: client_score_id.to_owned(),
            seconds,
            measured_at: None,
        },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn count_bolt_scores(db: &TestDatabase) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM bolt_scores")
        .fetch_one(&db.pool)
        .await
        .expect("the bolt_scores table is readable")
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
