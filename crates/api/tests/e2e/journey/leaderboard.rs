//! The boards, which are the one journey surface that counts people it must not
//! name.

use api::identity::USER_ID_HEADER;
use api::proto::ond::v1 as pb;

use super::{
    ADA, BEA, CAL, GET_LEADERBOARD, board, bolt_score, days_ago, hours_ago, minutes_session, name,
    profile, record, session,
};
use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web_with};

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

/// The streak board narrows its fold to people who have breathed recently, which
/// is the only way it stays bounded as the install base grows. What that must
/// not do is change an answer: somebody whose streak ran long and stopped is out
/// of the ranking either way, and somebody still on a run is in it with their
/// whole run counted, however far back it began.
#[tokio::test]
async fn a_streak_board_counts_the_whole_run_and_drops_the_lapsed() {
    let db = TestDatabase::create("journey_board_active_window").await;

    name(&db, ADA, "Ada").await;
    name(&db, BEA, "Bea").await;

    // Ada is on a six-day run reaching back well past the window the fold uses
    // to find her.
    record(
        &db,
        ADA,
        (0..6)
            .map(|day| {
                session(
                    &format!("dddd0000-0000-4000-8000-{day:012}"),
                    days_ago(i64::from(day)),
                )
            })
            .collect(),
    )
    .await
    .into_ok();

    // Bea had a longer run that ended a fortnight ago.
    record(
        &db,
        BEA,
        (10..20)
            .map(|day| {
                session(
                    &format!("dddd0000-0000-4000-8000-{day:012}"),
                    days_ago(i64::from(day)),
                )
            })
            .collect(),
    )
    .await
    .into_ok();

    let streaks = board(
        &db,
        ADA,
        pb::LeaderboardBoard::Streak,
        pb::LeaderboardScope::Global,
    )
    .await
    .into_ok();

    assert_eq!(
        streaks
            .entries
            .iter()
            .map(|entry| (entry.display_name.as_str(), entry.value))
            .collect::<Vec<_>>(),
        vec![("Ada", 6)],
        "the whole run counts, and a run that has lapsed is not a current streak"
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

    bolt_score(&db, ADA, 30).await.into_ok();
    bolt_score(&db, BEA, 18).await.into_ok();

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
