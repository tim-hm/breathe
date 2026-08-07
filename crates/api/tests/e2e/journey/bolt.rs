//! Controlled-pause measurements over the wire.

use super::{ADA, BEA, bolt_score, bolt_with, journey};
use crate::harness::TestDatabase;

/// The personal best is the server's answer rather than the client's, because a
/// client that was offline for three tests does not hold the history to compare
/// against. A lower score afterwards must not overwrite it.
#[tokio::test]
async fn a_bolt_score_is_a_personal_best_only_when_it_beats_the_history() {
    let db = TestDatabase::create("journey_bolt_best").await;

    let first = bolt_score(&db, ADA, 20).await.into_ok();
    assert_eq!((first.best_seconds, first.is_personal_best), (20, true));

    let lower = bolt_score(&db, ADA, 15).await.into_ok();
    assert_eq!((lower.best_seconds, lower.is_personal_best), (20, false));

    let higher = bolt_score(&db, ADA, 25).await.into_ok();
    assert_eq!((higher.best_seconds, higher.is_personal_best), (25, true));

    assert_eq!(
        journey(&db, ADA, 0).await.into_ok().best_bolt_seconds,
        Some(25),
        "the journey screen draws its BOLT card without a second round trip"
    );

    let nonsense = bolt_score(&db, ADA, 20_000).await;
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

async fn count_bolt_scores(db: &TestDatabase) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM bolt_scores")
        .fetch_one(&db.pool)
        .await
        .expect("the bolt_scores table is readable")
}
