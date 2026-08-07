//! The practice snapshot the assistant reads, over real inserts.
//!
//! No RPC serves the snapshot — it is prompt input — so these call
//! `practice_snapshot` directly against the harness pool, after writing history
//! through the same wire the iOS client uses. What is worth driving this way is
//! exactly what the unit tests cannot reach: the window and the grouping live
//! in SQL.

use api::identity::UserId;
use api::journey::{
    BoltSnapshot, MAX_SNAPSHOT_TECHNIQUES, PRACTICE_WINDOW_DAYS, PracticeSnapshot,
    practice_snapshot,
};
use api::proto::breathe::v1 as pb;
use chrono::{DateTime, Utc};

use super::{ADA, BEA, bolt_with, days_ago, minutes_session, record};
use crate::harness::TestDatabase;

fn user(id: &str) -> UserId {
    UserId(id.parse().expect("a fixture id is a valid uuid"))
}

fn technique_session(id: &str, slug: &str, started_at: DateTime<Utc>) -> pb::SessionRecord {
    pb::SessionRecord {
        technique_slug: slug.to_owned(),
        ..minutes_session(id, started_at, 1)
    }
}

async fn snapshot(db: &TestDatabase, id: &str) -> PracticeSnapshot {
    practice_snapshot(&db.pool, user(id))
        .await
        .expect("the snapshot assembles")
}

/// The window is the whole contract: the assistant phrases "the last 30 days",
/// so a session outside them must contribute nothing — not to the totals, not
/// to the day count, not to a technique's line.
#[tokio::test]
async fn the_snapshot_counts_only_the_window() {
    let db = TestDatabase::create("journey_snapshot_window").await;

    record(
        &db,
        ADA,
        vec![
            minutes_session("dddd0000-0000-4000-8000-000000000001", days_ago(40), 2),
            minutes_session("dddd0000-0000-4000-8000-000000000002", days_ago(2), 2),
            minutes_session("dddd0000-0000-4000-8000-000000000003", days_ago(1), 2),
        ],
    )
    .await
    .into_ok();

    let snapshot = snapshot(&db, ADA).await;

    assert_eq!(
        (snapshot.sessions, snapshot.minutes, snapshot.active_days),
        (2, 4, 2),
        "the forty-day-old session is history, not recent practice"
    );
    assert_eq!(snapshot.by_technique.len(), 1);
    assert_eq!(snapshot.by_technique[0].technique_slug, "box-breathing");
    assert_eq!(
        (
            snapshot.by_technique[0].sessions,
            snapshot.by_technique[0].minutes
        ),
        (2, 4)
    );
}

/// Only the busiest six techniques are named, busiest first, but every session
/// still counts — the cap bounds prompt lines, and a total that shrank with it
/// would understate exactly the scattered practice worth commenting on.
#[tokio::test]
async fn the_busiest_six_are_named_and_everything_is_counted() {
    let db = TestDatabase::create("journey_snapshot_top_six").await;

    // `practice-0` gets seven sessions down to `practice-6` getting one, so the
    // busiest-first order and the identity of the dropped slug are both known.
    let mut batch = Vec::new();
    for rank in 0..7u32 {
        for nth in 0..(7 - rank) {
            batch.push(technique_session(
                &format!("eeee0000-0000-4000-8000-0000{rank:04}{nth:04}"),
                &format!("practice-{rank}"),
                days_ago(i64::from(nth) + 1),
            ));
        }
    }
    record(&db, ADA, batch).await.into_ok();

    let snapshot = snapshot(&db, ADA).await;

    assert_eq!(snapshot.by_technique.len(), MAX_SNAPSHOT_TECHNIQUES);
    assert_eq!(
        snapshot
            .by_technique
            .iter()
            .map(|entry| (entry.technique_slug.as_str(), entry.sessions))
            .collect::<Vec<_>>(),
        vec![
            ("practice-0", 7),
            ("practice-1", 6),
            ("practice-2", 5),
            ("practice-3", 4),
            ("practice-4", 3),
            ("practice-5", 2),
        ],
        "busiest first, and the least-practised loses its line"
    );
    assert_eq!(
        (snapshot.sessions, snapshot.minutes),
        (28, 28),
        "the dropped technique's sessions still count"
    );
}

/// Before any practice the snapshot is zeroes rather than an error, and one
/// person's history never colours another's — the assistant will read this for
/// whoever asks.
#[tokio::test]
async fn an_unpractised_person_gets_a_zeroed_snapshot_of_their_own() {
    let db = TestDatabase::create("journey_snapshot_empty").await;

    record(
        &db,
        ADA,
        vec![minutes_session(
            "ffff0000-0000-4000-8000-000000000001",
            days_ago(1),
            2,
        )],
    )
    .await
    .into_ok();

    assert_eq!(
        snapshot(&db, BEA).await,
        PracticeSnapshot {
            window_days: u32::from(PRACTICE_WINDOW_DAYS),
            sessions: 0,
            minutes: 0,
            active_days: 0,
            by_technique: Vec::new(),
            bolt: None,
        }
    );
}

/// Best and latest are different folds of the same history: the later-measured
/// score is recorded first, so a "latest" that followed insertion order rather
/// than `measured_at` would answer with the older pause.
#[tokio::test]
async fn the_bolt_snapshot_is_best_latest_and_count() {
    let db = TestDatabase::create("journey_snapshot_bolt").await;

    bolt_with(
        &db,
        ADA,
        "9aaa0000-0000-4000-8000-000000000001",
        22,
        Some(days_ago(1)),
    )
    .await
    .into_ok();
    bolt_with(
        &db,
        ADA,
        "9aaa0000-0000-4000-8000-000000000002",
        30,
        Some(days_ago(10)),
    )
    .await
    .into_ok();

    assert_eq!(
        snapshot(&db, ADA).await.bolt,
        Some(BoltSnapshot {
            best: 30,
            latest: 22,
            count: 2,
        })
    );
}
