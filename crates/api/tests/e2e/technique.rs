//! `ListTechniques`, over the wire the iOS client actually uses.

use api::proto::breathe::v1 as pb;

use crate::harness::{TestDatabase, call_grpc_web};

const LIST_TECHNIQUES: &str = "/breathe.v1.TechniqueService/ListTechniques";

/// The bootstrap's acceptance criterion, minus the simulator: seeded rows in
/// Postgres reach a client as decoded protobuf, through the same router and the
/// same gRPC-Web framing the app uses.
#[tokio::test]
async fn the_seeded_catalogue_arrives_over_grpc_web() {
    let db = TestDatabase::create("seeded_catalogue").await;

    let response: pb::ListTechniquesResponse =
        call_grpc_web(db.app(), LIST_TECHNIQUES, &pb::ListTechniquesRequest {})
            .await
            .into_ok();

    assert!(
        !response.techniques.is_empty(),
        "the seed populates the catalogue"
    );

    for technique in &response.techniques {
        let slug = &technique.slug;
        assert_ne!(
            technique.goal,
            pb::TechniqueGoal::Unspecified as i32,
            "`{slug}` reached the client with an unspecified goal"
        );
        assert!(!technique.phases.is_empty(), "`{slug}` has no phases");

        for phase in &technique.phases {
            assert_ne!(
                phase.kind,
                pb::PhaseKind::Unspecified as i32,
                "`{slug}` has a phase of unspecified kind"
            );
            assert!(phase.duration_ms > 0, "`{slug}` has a zero-length phase");
        }
    }

    // Box breathing is four equal four-second beats by definition. Pinning one
    // known technique is what separates "the wire works" from "rows arrived
    // intact" — a grouping bug would still return four techniques.
    let box_breathing = response
        .techniques
        .iter()
        .find(|technique| technique.slug == "box-breathing")
        .expect("the seeded catalogue contains box breathing");

    assert_eq!(box_breathing.goal, pb::TechniqueGoal::Calm as i32);
    assert_eq!(
        box_breathing
            .phases
            .iter()
            .map(|phase| (phase.kind, phase.duration_ms))
            .collect::<Vec<_>>(),
        vec![
            (pb::PhaseKind::Inhale as i32, 4000),
            (pb::PhaseKind::HoldIn as i32, 4000),
            (pb::PhaseKind::Exhale as i32, 4000),
            (pb::PhaseKind::HoldOut as i32, 4000),
        ]
    );
}

/// `service.rs` groups phases through a `HashMap`, so nothing about the query's
/// `ORDER BY ordinal` survives into the response by accident. Inserting the
/// cycle out of order is what makes this assertion mean something — with rows
/// inserted in cycle order, an implementation that ignored `ordinal` entirely
/// would still pass.
#[tokio::test]
async fn phase_order_follows_ordinal_not_insertion_order() {
    let db = TestDatabase::create("phase_order").await;
    insert_technique(&db.pool, "order-probe", "CALM").await;

    for (ordinal, kind) in [(2, "EXHALE"), (0, "INHALE"), (1, "HOLD_IN")] {
        sqlx::query(
            r"INSERT INTO technique_phases (technique_id, ordinal, kind, duration_ms)
               VALUES ($1, $2, $3::phase_kind, $4)",
        )
        .bind("order-probe")
        .bind(ordinal)
        .bind(kind)
        .bind(1000)
        .execute(&db.pool)
        .await
        .expect("the fixture phase inserts");
    }

    let response: pb::ListTechniquesResponse =
        call_grpc_web(db.app(), LIST_TECHNIQUES, &pb::ListTechniquesRequest {})
            .await
            .into_ok();

    let probe = response
        .techniques
        .iter()
        .find(|technique| technique.slug == "order-probe")
        .expect("the fixture technique is listed");

    assert_eq!(
        probe
            .phases
            .iter()
            .map(|phase| phase.kind)
            .collect::<Vec<_>>(),
        vec![
            pb::PhaseKind::Inhale as i32,
            pb::PhaseKind::HoldIn as i32,
            pb::PhaseKind::Exhale as i32,
        ]
    );
}

/// A technique with no phase rows is corrupt data, and `service.rs` turns it
/// into `TechniqueError::Inconsistent`. What this pins is the rest of the path:
/// that the failure reaches the client as a non-zero `grpc-status` — the only
/// place a gRPC-Web client can see it, since the HTTP status stays 200 — rather
/// than as a quietly shortened list.
#[tokio::test]
async fn a_phaseless_technique_fails_the_call_rather_than_vanishing() {
    let db = TestDatabase::create("phaseless_technique").await;
    insert_technique(&db.pool, "phaseless", "RESET").await;

    let response = call_grpc_web::<_, pb::ListTechniquesResponse>(
        db.app(),
        LIST_TECHNIQUES,
        &pb::ListTechniquesRequest {},
    )
    .await;

    assert_eq!(response.status, tonic::Code::Internal as i32);
    assert!(
        response.message.is_none(),
        "a failed call must not also carry a partial catalogue"
    );
}

/// Fixture rows use the slug as the id: readable in a failure message, and
/// unique for the same reason the slug is.
async fn insert_technique(pool: &sqlx::PgPool, slug: &str, goal: &str) {
    sqlx::query(
        r"INSERT INTO techniques (id, slug, name, summary, goal, sort_order)
           VALUES ($1, $1, $2, '', $3::technique_goal, $4)",
    )
    .bind(slug)
    .bind(slug)
    .bind(goal)
    // Past the seeded catalogue, so fixtures sort last and the assertions above
    // about seeded data stay independent of them.
    .bind(1000)
    .execute(pool)
    .await
    .expect("the fixture technique inserts");
}
