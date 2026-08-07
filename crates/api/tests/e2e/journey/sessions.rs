//! Recording, deleting and reading back a person's own history.
//!
//! Almost everything here is about arithmetic that no compiler checks: a streak
//! is a fold over calendar days in a time zone the server does not store.

use api::proto::ond::v1 as pb;
use chrono::{DateTime, Duration, TimeZone, Utc};

use super::{
    ADA, BEA, GET_JOURNEY, days_ago, delete, hours_ago, journey, journey_page, prost_timestamp,
    record, session,
};
use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web_with};

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

/// The restore path after a reinstall, where the Keychain identity outlived the
/// sessions file. The server holds more than one page; a device that stopped at
/// the first one would silently drop the rest of somebody's journal, and their
/// totals would keep saying it was there.
#[tokio::test]
async fn a_restore_pages_through_more_history_than_one_page_holds() {
    let db = TestDatabase::create("journey_restore_paging").await;

    // More than the default page, and deliberately not a multiple of the page
    // asked for below, so the final page is short rather than exactly full.
    let recorded: usize = 57;
    let batch: Vec<pb::SessionRecord> = (1..=recorded)
        .map(|index| {
            session(
                &format!("cccc0000-0000-4000-8000-{index:012}"),
                hours_ago(i64::try_from(index).expect("a small count")),
            )
        })
        .collect();
    record(&db, ADA, batch).await.into_ok();

    let strip = journey(&db, ADA, 0).await.into_ok();
    assert_eq!(
        strip.recent_sessions.len(),
        50,
        "the journey screen still gets its bounded strip"
    );
    assert!(
        strip.next_page_token.is_some(),
        "and is told there is more behind it"
    );

    let mut restored: Vec<String> = Vec::new();
    let mut page_token = None;
    loop {
        let page = journey_page(&db, ADA, 0, Some(20), page_token)
            .await
            .into_ok();
        restored.extend(
            page.recent_sessions
                .iter()
                .map(|record| record.client_session_id.clone()),
        );

        page_token = page.next_page_token;
        if page_token.is_none() {
            break;
        }
        assert!(restored.len() <= recorded, "the paging terminates");
    }

    assert_eq!(restored.len(), recorded);
    let mut unique = restored.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(
        unique.len(),
        recorded,
        "no session is served twice across a page boundary"
    );

    let malformed = journey_page(&db, ADA, 0, None, Some("not-a-token".to_owned())).await;
    assert_eq!(
        malformed.status,
        tonic::Code::InvalidArgument as i32,
        "a token the server did not issue is refused rather than silently restarting"
    );
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

/// The other half of the tombstone contract. A session deleted on a device has
/// to be gone from the server too, or the next restore hands it straight back —
/// and a `client_session_id` is minted on a phone, so the same value can name
/// two people's sessions. Deleting one must not touch the other.
#[tokio::test]
async fn a_deleted_session_stays_gone_and_only_for_the_caller() {
    let db = TestDatabase::create("journey_delete_scoping").await;
    let shared = "aaaa0000-0000-4000-8000-000000000001";

    record(
        &db,
        ADA,
        vec![
            session(shared, hours_ago(1)),
            session("aaaa0000-0000-4000-8000-000000000002", hours_ago(2)),
        ],
    )
    .await
    .into_ok();
    record(&db, BEA, vec![session(shared, hours_ago(1))])
        .await
        .into_ok();

    let deleted = delete(&db, ADA, vec![shared.to_owned()]).await.into_ok();
    assert_eq!(deleted.deleted, 1);

    let theirs = journey(&db, ADA, 0).await.into_ok();
    assert_eq!(
        theirs
            .recent_sessions
            .iter()
            .map(|record| record.client_session_id.as_str())
            .collect::<Vec<_>>(),
        vec!["aaaa0000-0000-4000-8000-000000000002"],
        "a restore must not hand back what was deleted"
    );

    let untouched = journey(&db, BEA, 0).await.into_ok();
    assert_eq!(
        untouched.recent_sessions.len(),
        1,
        "the same id names a different person's session"
    );

    // The client keeps its tombstone until the call succeeds, so it is entitled
    // to send the same id again — and the second attempt has to be free.
    let repeated = delete(&db, ADA, vec![shared.to_owned()]).await.into_ok();
    assert_eq!(repeated.deleted, 0);
    assert_eq!(
        journey(&db, ADA, 0).await.into_ok().recent_sessions.len(),
        1
    );
}

/// A tombstone can name a session the server never held — one recorded and
/// deleted with no signal in between. Refusing it would strand the tombstone on
/// the device forever, which is exactly the state this RPC exists to end.
#[tokio::test]
async fn an_unknown_id_is_forgotten_without_complaint() {
    let db = TestDatabase::create("journey_delete_unknown").await;

    record(
        &db,
        ADA,
        vec![session(
            "bbbb0000-0000-4000-8000-000000000001",
            hours_ago(1),
        )],
    )
    .await
    .into_ok();

    let unknown = delete(
        &db,
        ADA,
        vec![
            "bbbb0000-0000-4000-8000-000000000002".to_owned(),
            "bbbb0000-0000-4000-8000-000000000003".to_owned(),
        ],
    )
    .await
    .into_ok();
    assert_eq!(unknown.deleted, 0);
    assert_eq!(
        journey(&db, ADA, 0).await.into_ok().recent_sessions.len(),
        1
    );

    let malformed = delete(&db, ADA, vec!["not-a-uuid".to_owned()]).await;
    assert_eq!(malformed.status, tonic::Code::InvalidArgument as i32);

    let empty = delete(&db, ADA, vec![]).await;
    assert_eq!(empty.status, tonic::Code::InvalidArgument as i32);
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
            limit: None,
            page_token: None,
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
