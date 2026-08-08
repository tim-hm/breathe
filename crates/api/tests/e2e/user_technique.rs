//! `UserTechniqueService`, over the wire the iOS client uses.

use api::identity::USER_ID_HEADER;
use api::proto::ond::v1 as pb;
use tonic::Code;

use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web, call_grpc_web_with};

const LIST: &str = "/ond.v1.UserTechniqueService/ListUserTechniques";
const CREATE: &str = "/ond.v1.UserTechniqueService/CreateUserTechnique";
const UPDATE: &str = "/ond.v1.UserTechniqueService/UpdateUserTechnique";
const DELETE: &str = "/ond.v1.UserTechniqueService/DeleteUserTechnique";

/// Two stable, valid identities. Fixed rather than random so a failing test
/// leaves rows someone can go and look at.
const USER: &str = "3f2b1c4d-0000-4000-8000-000000000101";
const OTHER_USER: &str = "3f2b1c4d-0000-4000-8000-000000000102";

/// The acceptance criterion, minus the simulator: something composed on one
/// device is listed, whole and playable, by another device sending the same id.
///
/// "Playable" is the load-bearing word. The response is a `Technique` — the same
/// message the catalogue serves — so what this pins is that every field the
/// client's `SessionTimeline` reads off a curated technique is present on an
/// authored one, including the per-phase range the dials render from.
#[tokio::test]
async fn an_authored_exercise_syncs_to_a_second_device() {
    let db = TestDatabase::create("user_technique_sync").await;

    let created = create(&db, USER, Some(draft()))
        .await
        .into_ok()
        .technique
        .expect("a create answers with the technique it stored");

    assert!(!created.id.is_empty());
    assert_eq!(created.name, "Long exhale, mine");
    assert_eq!(created.goal, pb::TechniqueGoal::Sleep as i32);
    assert_eq!(created.recommended_rounds, 1);

    // A second call carrying the same identity is the whole of "it syncs": the
    // rows are the server's, so a device that has never seen this technique gets
    // it by asking.
    let listed = list(&db, USER).await.into_ok();
    let [technique] = &listed.techniques[..] else {
        panic!("the one authored exercise comes back");
    };

    assert_eq!(technique.id, created.id);
    assert_eq!(technique.slug, created.slug);
    assert_eq!(
        *technique, created,
        "listing and creating describe it alike"
    );

    let [stage] = &technique.stages[..] else {
        panic!("this draft has one stage");
    };
    assert_eq!(stage.cycles, 10);
    assert!(
        !stage.open_ended,
        "an authored stage is never one the person has to end"
    );
    assert_eq!(
        stage
            .phases
            .iter()
            .map(|phase| (phase.kind, phase.duration_ms))
            .collect::<Vec<_>>(),
        vec![
            (pb::PhaseKind::Inhale as i32, 4000),
            (pb::PhaseKind::Exhale as i32, 8000),
        ]
    );

    // Every phase arrives with a range containing its own duration, which is
    // what the client requires to render a dial at all — and what it rejects the
    // whole technique for lacking.
    for phase in &stage.phases {
        assert!(phase.min_duration_ms <= phase.duration_ms);
        assert!(phase.duration_ms <= phase.max_duration_ms);
    }
}

/// A sequence comes back in the order it was composed in, and reordering it
/// reorders it.
///
/// The one thing three parallel tables can get wrong that a single row could
/// not. Stages and phases are stored as ordinals across two child tables and
/// reassembled by a grouping on the way out, so a sequence whose stages arrive
/// shuffled is an exercise that plays a different exercise — silently, because
/// every stage is individually valid.
///
/// The edit reverses the stages rather than changing them, which is what pins
/// the rewrite: `replace` deletes and re-inserts every ordinal, so a path that
/// merged instead of replacing would answer with the old order.
#[tokio::test]
async fn a_sequence_keeps_the_order_it_was_composed_in() {
    let db = TestDatabase::create("user_technique_sequence").await;

    let created = create(&db, USER, Some(sequence()))
        .await
        .into_ok()
        .technique
        .expect("a sequence is stored whole");

    assert_eq!(created.recommended_rounds, 3);
    assert_eq!(shape(&created), vec![(6, 2), (1, 3), (4, 2)]);
    assert_eq!(
        created.stages[1]
            .phases
            .iter()
            .map(|phase| (phase.kind, phase.duration_ms))
            .collect::<Vec<_>>(),
        vec![
            (pb::PhaseKind::Inhale as i32, 4000),
            (pb::PhaseKind::HoldIn as i32, 8000),
            (pb::PhaseKind::Exhale as i32, 8000),
        ],
        "the middle stage keeps its own pattern, in its own order"
    );

    let listed = list(&db, USER).await.into_ok();
    assert_eq!(
        listed.techniques,
        vec![created.clone()],
        "listing and creating describe a sequence alike"
    );

    let mut reordered = sequence();
    reordered.stages.reverse();

    let updated = call_grpc_web_with::<_, pb::UpdateUserTechniqueResponse>(
        db.app(),
        UPDATE,
        &pb::UpdateUserTechniqueRequest {
            id: created.id.clone(),
            draft: Some(reordered),
        },
        &[(USER_ID_HEADER, USER)],
    )
    .await
    .into_ok()
    .technique
    .expect("the update answers with the technique it stored");

    assert_eq!(shape(&updated), vec![(4, 2), (1, 3), (6, 2)]);
    assert_eq!(
        list(&db, USER).await.into_ok().techniques,
        vec![updated],
        "and the stored order is the reordered one"
    );
}

/// The seeded ranges bound an authored exercise, and they do it here rather than
/// only in the composer.
///
/// A client is free to render whatever dial it likes; the four-minute inhale
/// below is what a client that renders none, or one that has drifted from the
/// seed, would post. The catalogue's widest seeded inhale is ten seconds.
#[tokio::test]
async fn a_phase_outside_the_seeded_range_is_refused_by_the_server() {
    let db = TestDatabase::create("user_technique_range").await;

    let mut reckless = draft();
    reckless.stages[0].phases[0].duration_ms = 240_000;

    let refused = create(&db, USER, Some(reckless)).await;

    assert_eq!(refused.status, Code::InvalidArgument as i32);
    assert!(
        list(&db, USER).await.into_ok().techniques.is_empty(),
        "a refused draft stores nothing"
    );
}

/// The limits a composer renders from are derived from the catalogue rather
/// than declared, so this asserts against the seed's own numbers.
///
/// The retention in the Wim Hof round is a sixty-second hold, and it is
/// open-ended: the person ends it. Its range must not become the ceiling on a
/// hold somebody schedules on a clock, which is the one way this derivation
/// could quietly go wrong.
#[tokio::test]
async fn the_authoring_limits_come_from_the_seeded_ranges() {
    let db = TestDatabase::create("user_technique_limits").await;

    let limits = list(&db, USER)
        .await
        .into_ok()
        .limits
        .expect("the limits are served even to somebody with no techniques");

    assert!(limits.max_techniques > 0);
    assert!(limits.max_stages > 0);
    assert!(limits.max_phases_per_stage > 0);
    assert!(limits.max_cycles > 0);
    assert!(limits.max_rounds > 0);
    assert!(limits.max_name_chars > 0);

    let hold_out = limits
        .phases
        .iter()
        .find(|limit| limit.kind == pb::PhaseKind::HoldOut as i32)
        .expect("the catalogue seeds empty-lung holds in closed stages");

    assert!(
        hold_out.max_duration_ms < 60_000,
        "the open-ended retention's sixty seconds leaked into a scheduled hold's ceiling"
    );

    for limit in &limits.phases {
        assert_ne!(limit.kind, pb::PhaseKind::Unspecified as i32);
        assert!(limit.min_duration_ms > 0);
        assert!(limit.min_duration_ms <= limit.max_duration_ms);
    }
}

/// Editing replaces the whole exercise, including a shape change — a phase
/// removed from the middle renumbers everything after it, which is the case a
/// rewrite gets right for free and a patch does not.
#[tokio::test]
async fn editing_replaces_the_whole_exercise() {
    let db = TestDatabase::create("user_technique_edit").await;

    let created = create(&db, USER, Some(draft()))
        .await
        .into_ok()
        .technique
        .expect("the create succeeds");

    let mut edited = draft();
    edited.name = "Shorter".to_owned();
    edited.stages[0].phases.truncate(1);
    edited.stages[0].cycles = 4;

    let updated = call_grpc_web_with::<_, pb::UpdateUserTechniqueResponse>(
        db.app(),
        UPDATE,
        &pb::UpdateUserTechniqueRequest {
            id: created.id.clone(),
            draft: Some(edited),
        },
        &[(USER_ID_HEADER, USER)],
    )
    .await
    .into_ok()
    .technique
    .expect("the update answers with the technique it stored");

    assert_eq!(updated.id, created.id, "an edit keeps its identity");
    assert_eq!(updated.name, "Shorter");
    assert_eq!(updated.stages[0].phases.len(), 1);
    assert_eq!(updated.stages[0].cycles, 4);

    let listed = list(&db, USER).await.into_ok();
    assert_eq!(listed.techniques.len(), 1, "an edit is not a second copy");
    assert_eq!(listed.techniques[0], updated);
}

/// Deleting removes it, and deleting it again succeeds.
///
/// The second half is the point: a client that retried a delete whose answer it
/// never saw must converge rather than be told about a technique the person can
/// no longer see.
#[tokio::test]
async fn deleting_is_idempotent() {
    let db = TestDatabase::create("user_technique_delete").await;

    let created = create(&db, USER, Some(draft()))
        .await
        .into_ok()
        .technique
        .expect("the create succeeds");

    for _ in 0..2 {
        let deleted = call_grpc_web_with::<_, pb::DeleteUserTechniqueResponse>(
            db.app(),
            DELETE,
            &pb::DeleteUserTechniqueRequest {
                id: created.id.clone(),
            },
            &[(USER_ID_HEADER, USER)],
        )
        .await;

        assert_eq!(deleted.status, Code::Ok as i32);
    }

    assert!(list(&db, USER).await.into_ok().techniques.is_empty());
}

/// One person's exercises are not another's, on every RPC that names an id.
///
/// The whole credential is a UUID somebody generated, so the ownership predicate
/// is the only thing between two callers — and it has to be on the write paths,
/// not just the read.
#[tokio::test]
async fn one_persons_exercises_are_invisible_to_another() {
    let db = TestDatabase::create("user_technique_isolation").await;

    let mine = create(&db, USER, Some(draft()))
        .await
        .into_ok()
        .technique
        .expect("the create succeeds");

    assert!(
        list(&db, OTHER_USER).await.into_ok().techniques.is_empty(),
        "somebody else's list is empty"
    );

    let stolen = call_grpc_web_with::<_, pb::UpdateUserTechniqueResponse>(
        db.app(),
        UPDATE,
        &pb::UpdateUserTechniqueRequest {
            id: mine.id.clone(),
            draft: Some(draft()),
        },
        &[(USER_ID_HEADER, OTHER_USER)],
    )
    .await;

    assert_eq!(stolen.status, Code::NotFound as i32);

    let deleted = call_grpc_web_with::<_, pb::DeleteUserTechniqueResponse>(
        db.app(),
        DELETE,
        &pb::DeleteUserTechniqueRequest { id: mine.id },
        &[(USER_ID_HEADER, OTHER_USER)],
    )
    .await;

    assert_eq!(
        deleted.status,
        Code::Ok as i32,
        "a delete stays idempotent for a stranger"
    );
    assert_eq!(
        list(&db, USER).await.into_ok().techniques.len(),
        1,
        "and it deleted nothing"
    );
}

/// There is no anonymous half of this service, unlike the catalogue's.
#[tokio::test]
async fn an_unidentified_caller_has_no_exercises_to_read() {
    let db = TestDatabase::create("user_technique_anonymous").await;

    let response =
        call_grpc_web::<_, pb::ListUserTechniquesResponse>(db.app(), LIST, &request()).await;

    assert_eq!(response.status, Code::Unauthenticated as i32);
}

/// A person's own exercises are theirs, but the number of them is this
/// database's — and the caller's whole credential is a UUID they minted.
#[tokio::test]
async fn the_number_a_person_may_keep_is_bounded() {
    let db = TestDatabase::create("user_technique_ceiling").await;

    let ceiling = list(&db, USER)
        .await
        .into_ok()
        .limits
        .expect("the limits are served")
        .max_techniques;

    for index in 0..ceiling {
        let mut another = draft();
        another.name = format!("Mine {index}");
        assert_eq!(
            create(&db, USER, Some(another)).await.status,
            Code::Ok as i32,
            "the {index}th exercise is still inside the ceiling"
        );
    }

    assert_eq!(
        create(&db, USER, Some(draft())).await.status,
        Code::ResourceExhausted as i32
    );
}

/// Something plainly inside every seeded range: four seconds in, eight out, ten
/// times over. The exercise somebody who has found what works for them would
/// actually write down.
fn draft() -> pb::TechniqueDraft {
    pb::TechniqueDraft {
        name: "Long exhale, mine".to_owned(),
        goal: pb::TechniqueGoal::Sleep as i32,
        stages: vec![pb::DraftStage {
            phases: vec![
                pb::DraftPhase {
                    kind: pb::PhaseKind::Inhale as i32,
                    duration_ms: 4000,
                },
                pb::DraftPhase {
                    kind: pb::PhaseKind::Exhale as i32,
                    duration_ms: 8000,
                },
            ],
            cycles: 10,
        }],
        rounds: 1,
    }
}

/// Three differently-shaped stages, three times over — the user-built equivalent
/// of a staged protocol. Every stage has a distinct cycle count and phase count
/// so that a stage arriving in the wrong slot reads as a wrong number rather
/// than as a coincidence.
fn sequence() -> pb::TechniqueDraft {
    pb::TechniqueDraft {
        name: "Wake, hold, settle".to_owned(),
        goal: pb::TechniqueGoal::Energy as i32,
        stages: vec![
            stage(6, &[(pb::PhaseKind::Inhale, 2000), (pb::PhaseKind::Exhale, 2000)]),
            stage(
                1,
                &[
                    (pb::PhaseKind::Inhale, 4000),
                    (pb::PhaseKind::HoldIn, 8000),
                    (pb::PhaseKind::Exhale, 8000),
                ],
            ),
            stage(4, &[(pb::PhaseKind::Inhale, 3000), (pb::PhaseKind::Exhale, 6000)]),
        ],
        rounds: 3,
    }
}

fn stage(cycles: u32, phases: &[(pb::PhaseKind, u32)]) -> pb::DraftStage {
    pb::DraftStage {
        phases: phases
            .iter()
            .map(|(kind, duration_ms)| pb::DraftPhase {
                kind: *kind as i32,
                duration_ms: *duration_ms,
            })
            .collect(),
        cycles,
    }
}

/// Each stage as its cycle count and how many phases it holds — enough to tell
/// three stages apart without restating every duration.
fn shape(technique: &pb::Technique) -> Vec<(u32, usize)> {
    technique
        .stages
        .iter()
        .map(|stage| (stage.cycles, stage.phases.len()))
        .collect()
}

const fn request() -> pb::ListUserTechniquesRequest {
    pb::ListUserTechniquesRequest {}
}

async fn list(db: &TestDatabase, user: &str) -> GrpcWebResponse<pb::ListUserTechniquesResponse> {
    call_grpc_web_with(db.app(), LIST, &request(), &[(USER_ID_HEADER, user)]).await
}

async fn create(
    db: &TestDatabase,
    user: &str,
    draft: Option<pb::TechniqueDraft>,
) -> GrpcWebResponse<pb::CreateUserTechniqueResponse> {
    call_grpc_web_with(
        db.app(),
        CREATE,
        &pb::CreateUserTechniqueRequest { draft },
        &[(USER_ID_HEADER, user)],
    )
    .await
}
