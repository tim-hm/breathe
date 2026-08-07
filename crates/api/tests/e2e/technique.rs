//! `ListTechniques` and `ListFoundations`, over the wire the iOS client uses.

use api::proto::breathe::v1 as pb;

use crate::harness::{TestDatabase, call_grpc_web};

const LIST_TECHNIQUES: &str = "/breathe.v1.TechniqueService/ListTechniques";
const LIST_FOUNDATIONS: &str = "/breathe.v1.TechniqueService/ListFoundations";

/// The bootstrap's acceptance criterion, minus the simulator: seeded rows in
/// Postgres reach a client as decoded protobuf, through the same router and the
/// same gRPC-Web framing the app uses.
#[tokio::test]
async fn the_seeded_catalogue_arrives_over_grpc_web() {
    let db = TestDatabase::create("seeded_catalogue").await;
    let response = list_techniques(&db).await;

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
        assert!(!technique.stages.is_empty(), "`{slug}` has no stages");
        assert!(
            technique.recommended_rounds > 0,
            "`{slug}` recommends no rounds, which is a session with nothing to play"
        );

        for stage in &technique.stages {
            assert!(
                !stage.phases.is_empty(),
                "`{slug}` has a stage with no phases"
            );
            assert!(stage.cycles > 0, "`{slug}` has a stage playing no cycles");

            for phase in &stage.phases {
                assert_ne!(
                    phase.kind,
                    pb::PhaseKind::Unspecified as i32,
                    "`{slug}` has a phase of unspecified kind"
                );
                assert!(phase.duration_ms > 0, "`{slug}` has a zero-length phase");
            }
        }
    }

    // Box breathing is four equal four-second beats by definition. Pinning one
    // known technique is what separates "the wire works" from "rows arrived
    // intact" — a grouping bug would still return nine techniques.
    let box_breathing = find(&response, "box-breathing");
    let [stage] = &box_breathing.stages[..] else {
        panic!("box breathing is a single stage");
    };

    assert_eq!(box_breathing.goal, pb::TechniqueGoal::Calm as i32);
    assert_eq!(
        stage
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

    // A stage's cycle count has both a proto zero value and a schema CHECK
    // sitting under it, so a service that never read it would still return a
    // plausible catalogue. Two techniques differing by an order of magnitude are
    // what prove the curated value made the trip.
    assert_eq!(find(&response, "physiological-sigh").stages[0].cycles, 3);
    assert_eq!(find(&response, "bellows-breath").stages[0].cycles, 20);
}

/// The free tier, over the wire.
///
/// The whole catalogue is served either way — a locked technique is listed and
/// described, because the client's job is to invite rather than to hide — so the
/// only thing separating the two tiers on this call is one boolean per row, and
/// nothing else in the response would look wrong if it were dropped. That is
/// exactly what makes it worth an assertion: the free tier is a promise, and
/// this is the only place in the pipeline where the promise is visible.
#[tokio::test]
async fn the_free_techniques_arrive_unlocked_and_the_rest_do_not() {
    let db = TestDatabase::create("free_tier_flag").await;
    let response = list_techniques(&db).await;

    let free = response
        .techniques
        .iter()
        .filter(|technique| !technique.requires_subscription)
        .count();

    // Which two are free is `seed.rs`'s decision and its test; what this pins is
    // that the distinction survives the wire at all, and that both sides of it
    // are served.
    assert!(free > 0, "no technique arrived unlocked");
    assert!(
        response.techniques.len() > free,
        "the locked techniques are served too, or there is nothing to sell"
    );
}

/// The multi-stage model exists for this technique, and every part of its shape
/// is load-bearing: the retention has to arrive between the fast breaths and the
/// recovery hold, flagged open-ended, or the client either schedules a hold the
/// person is supposed to end or strands them on one that never ends. The rounds
/// and the safety copy travel with it.
#[tokio::test]
async fn the_wim_hof_rounds_arrive_as_ordered_stages() {
    let db = TestDatabase::create("wim_hof_stages").await;
    let response = list_techniques(&db).await;

    let wim_hof = find(&response, "wim-hof-rounds");
    let [breaths, retention, recovery] = &wim_hof.stages[..] else {
        panic!(
            "the Wim Hof-style rounds are three stages, not {}",
            wim_hof.stages.len()
        );
    };

    assert_eq!(wim_hof.goal, pb::TechniqueGoal::Energy as i32);
    assert_eq!(wim_hof.recommended_rounds, 3);

    assert!(!breaths.open_ended);
    assert_eq!(breaths.cycles, 30);
    assert_eq!(
        breaths
            .phases
            .iter()
            .map(|phase| phase.kind)
            .collect::<Vec<_>>(),
        vec![pb::PhaseKind::Inhale as i32, pb::PhaseKind::Exhale as i32]
    );

    assert!(retention.open_ended, "the retention is ended by the person");
    assert_eq!(retention.cycles, 1);
    assert_eq!(
        retention
            .phases
            .iter()
            .map(|phase| phase.kind)
            .collect::<Vec<_>>(),
        vec![pb::PhaseKind::HoldOut as i32]
    );

    assert!(!recovery.open_ended);
    assert_eq!(recovery.cycles, 1);
    assert_eq!(
        recovery
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

    // The one technique in the catalogue that can make someone faint carries the
    // strongest copy in the app, and it has to reach the session screen.
    assert!(wim_hof.safety_note.contains("water"));
    assert!(wim_hof.safety_note.contains("driv"));
    assert!(
        find(&response, "box-breathing").safety_note.is_empty(),
        "a technique with nothing to warn about carries no warning"
    );
}

/// The dials are rendered from this data, so a range that arrives collapsed to
/// zero leaves every client with a slider it cannot place a handle on. The
/// invariant holds catalogue-wide; the pinned technique proves the *curated*
/// range travelled rather than a copy of the default.
#[tokio::test]
async fn phase_dial_ranges_reach_the_client() {
    let db = TestDatabase::create("phase_dial_ranges").await;
    let response = list_techniques(&db).await;

    for technique in &response.techniques {
        for stage in &technique.stages {
            for phase in &stage.phases {
                assert!(
                    phase.min_duration_ms > 0
                        && phase.min_duration_ms <= phase.duration_ms
                        && phase.duration_ms <= phase.max_duration_ms,
                    "`{}` has a {}ms phase outside its {}–{}ms range",
                    technique.slug,
                    phase.duration_ms,
                    phase.min_duration_ms,
                    phase.max_duration_ms
                );
            }
        }
    }

    let exhale = &find(&response, "extended-exhale").stages[0].phases[1];
    assert_eq!(exhale.kind, pb::PhaseKind::Exhale as i32);
    assert_eq!(
        (
            exhale.min_duration_ms,
            exhale.duration_ms,
            exhale.max_duration_ms
        ),
        (6000, 6000, 8000),
        "the six-to-eight-second exhale is the evidence-based range, not a widened default"
    );
}

/// Public reference data on the same footing as the catalogue: no auth, no
/// pagination, curated order. The order is the assertion — these are the
/// questions in the sequence they occur to someone learning, and a service that
/// returned them by primary key would look identical until read.
#[tokio::test]
async fn the_foundations_arrive_over_grpc_web() {
    let db = TestDatabase::create("foundations").await;

    let response: pb::ListFoundationsResponse =
        call_grpc_web(db.app(), LIST_FOUNDATIONS, &pb::ListFoundationsRequest {})
            .await
            .into_ok();

    assert_eq!(
        response
            .topics
            .iter()
            .map(|topic| topic.slug.as_str())
            .collect::<Vec<_>>(),
        vec![
            "why-it-works",
            "belly-or-chest",
            "nose-or-mouth",
            "how-to-exhale",
            "how-slow",
            "sitting-or-lying",
            "eyes-open-or-closed",
        ]
    );

    for topic in &response.topics {
        assert!(!topic.question.is_empty(), "`{}` asks nothing", topic.slug);
        assert!(!topic.answer.is_empty(), "`{}` answers nothing", topic.slug);
    }
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
    insert_stage(&db.pool, "order-probe", 0).await;

    for (ordinal, kind) in [(2, "EXHALE"), (0, "INHALE"), (1, "HOLD_IN")] {
        sqlx::query(
            r"INSERT INTO technique_phases
                 (technique_id, stage_ordinal, ordinal, kind, duration_ms,
                  min_duration_ms, max_duration_ms)
               VALUES ($1, 0, $2, $3::phase_kind, 1000, 1000, 1000)",
        )
        .bind("order-probe")
        .bind(ordinal)
        .bind(kind)
        .execute(&db.pool)
        .await
        .expect("the fixture phase inserts");
    }

    let response = list_techniques(&db).await;
    let probe = find(&response, "order-probe");

    assert_eq!(
        probe.stages[0]
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

/// A technique with no stage rows is corrupt data, and `service.rs` turns it
/// into `TechniqueError::Inconsistent`. What this pins is the rest of the path:
/// that the failure reaches the client as a non-zero `grpc-status` — the only
/// place a gRPC-Web client can see it, since the HTTP status stays 200 — rather
/// than as a quietly shortened list.
#[tokio::test]
async fn a_stageless_technique_fails_the_call_rather_than_vanishing() {
    let db = TestDatabase::create("stageless_technique").await;
    insert_technique(&db.pool, "stageless", "RESET").await;

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

async fn list_techniques(db: &TestDatabase) -> pb::ListTechniquesResponse {
    call_grpc_web(db.app(), LIST_TECHNIQUES, &pb::ListTechniquesRequest {})
        .await
        .into_ok()
}

fn find<'a>(response: &'a pb::ListTechniquesResponse, slug: &str) -> &'a pb::Technique {
    response
        .techniques
        .iter()
        .find(|technique| technique.slug == slug)
        .unwrap_or_else(|| panic!("the catalogue contains `{slug}`"))
}

/// Fixture rows use the slug as the id: readable in a failure message, and
/// unique for the same reason the slug is.
async fn insert_technique(pool: &sqlx::PgPool, slug: &str, goal: &str) {
    sqlx::query(
        // `requires_subscription` is stated rather than defaulted because the
        // column has no default — the same reason `seed.rs` has to state it.
        r"INSERT INTO techniques
              (id, slug, name, summary, goal, sort_order, requires_subscription)
           VALUES ($1, $1, $2, '', $3::technique_goal, $4, true)",
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

async fn insert_stage(pool: &sqlx::PgPool, technique_id: &str, ordinal: i32) {
    sqlx::query(
        r"INSERT INTO technique_stages (technique_id, ordinal, cycles, open_ended)
           VALUES ($1, $2, 1, false)",
    )
    .bind(technique_id)
    .bind(ordinal)
    .execute(pool)
    .await
    .expect("the fixture stage inserts");
}
