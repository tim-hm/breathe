//! `AssistantService`, over the wire the iOS client uses, against a scripted
//! model.
//!
//! No network and no key. The seam in `features::assistant::model` exists so
//! that everything worth testing here — validation, quota, the breaker, the
//! fallback, and the streaming frames — is testable deterministically; the only
//! code these tests do not reach is the thin layer in `openrouter` that turns a
//! `ModelRequest` into an HTTP body.

use std::sync::Arc;
use std::time::Duration;

use api::assistant::{GuardedModelClient, ModelClient, ModelError};
use api::entitlement::Tier;
use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;

use crate::harness::{
    ScriptedModel, TestDatabase, allowance, call_grpc_web_stream_with, call_grpc_web_with,
};

const GET_RECOMMENDATION: &str = "/breathe.v1.AssistantService/GetRecommendation";
const EXPLAIN_TECHNIQUE: &str = "/breathe.v1.AssistantService/ExplainTechnique";

const USER: &str = "5c4d3e2f-0000-4000-8000-000000000001";
const OTHER_USER: &str = "5c4d3e2f-0000-4000-8000-000000000002";

/// The contract the client relies on: every slug it is handed resolves in the
/// catalogue it already holds. The model here names one real technique among
/// three inventions, and only the real one survives — an unfiltered path would
/// send the client to `moon-breathing`, which is a dead row rather than a
/// visible failure.
#[tokio::test]
async fn only_real_slugs_reach_the_client() {
    let db = TestDatabase::create("assistant_slug_validation").await;
    let model = ScriptedModel::always(Ok("moon-breathing | Invented.\n\
         box-breathing | Equal counts give you something to hold on to.\n\
         cosmic-sigh | Also invented.\n\
         quantum-breathing | Still invented."
        .to_owned()));

    let response = recommend(&db, model.clone(), USER).await;

    assert_eq!(response.source, pb::AssistantSource::Model as i32);
    let slugs: Vec<&str> = response
        .recommendations
        .iter()
        .map(|item| item.technique_slug.as_str())
        .collect();
    assert_eq!(slugs, vec!["box-breathing"]);
    assert_eq!(model.calls(), 1);
}

/// A reply naming nothing real is not an empty list — it is the fallback, and
/// the flag says so. This is the case that decides whether a client ever has to
/// render "the assistant had nothing to say".
#[tokio::test]
async fn a_wholly_invented_reply_falls_back_to_the_rules() {
    let db = TestDatabase::create("assistant_invented_reply").await;
    let model = ScriptedModel::always(Ok("moon-breathing | Nope.\ncosmic-sigh | Nope.".to_owned()));

    let response = recommend(&db, model, USER).await;

    assert_eq!(response.source, pb::AssistantSource::Fallback as i32);
    assert!(!response.recommendations.is_empty());
    for item in &response.recommendations {
        assert!(!item.technique_slug.is_empty());
        assert!(!item.reason.is_empty());
    }
}

/// The rules rank by the goals somebody picked, so the fallback is a plainer
/// version of the same judgement rather than a fixed list. Sleep first here, and
/// the sleep techniques lead.
#[tokio::test]
async fn the_fallback_ranks_by_the_goals_they_picked() {
    let db = TestDatabase::create("assistant_fallback_ranking").await;
    set_goals(&db, USER, &[pb::TechniqueGoal::Sleep]).await;

    let model = ScriptedModel::always(Err(ModelError::Failed("down".to_owned())));
    let response = recommend(&db, model, USER).await;

    assert_eq!(response.source, pb::AssistantSource::Fallback as i32);
    let leading = &response.recommendations[0].technique_slug;
    assert!(
        ["four-seven-eight", "extended-exhale"].contains(&leading.as_str()),
        "a sleep goal should lead with a sleep technique, got `{leading}`"
    );
}

/// The quota is a spend ceiling that has to bind, and its exhaustion must be a
/// degraded answer rather than an error: the person asked a question and gets
/// one, flagged. Without the flag a client would present rule-based copy as
/// personalised.
///
/// The ceiling is Coach's, because Coach is the only tier that reaches the
/// model at all — who is allowed past the gate is `entitlement.rs`'s business
/// and this is about what happens once they are.
#[tokio::test]
async fn an_exhausted_quota_answers_from_the_rules() {
    let db = TestDatabase::create("assistant_quota").await;
    let model = ScriptedModel::always(Ok("box-breathing | Steady.".to_owned()));
    let allowance = allowance(Tier::Coach);

    for _ in 0..allowance {
        let response = recommend(&db, model.clone(), USER).await;
        assert_eq!(response.source, pb::AssistantSource::Model as i32);
    }

    let exhausted = recommend(&db, model.clone(), USER).await;
    assert_eq!(exhausted.source, pb::AssistantSource::Fallback as i32);
    assert!(!exhausted.recommendations.is_empty());

    assert_eq!(
        model.calls(),
        allowance,
        "the call past the limit must not reach the model at all"
    );

    // The allowance is per person, so somebody else is unaffected by it — the
    // counter being keyed on the caller is what stops one heavy user from
    // silencing the assistant for everybody.
    let other = recommend(&db, model, OTHER_USER).await;
    assert_eq!(other.source, pb::AssistantSource::Model as i32);
}

/// The breaker's whole purpose: stop paying for a provider that is down, and
/// start again once it might not be. Both halves are asserted through the call
/// count, because a breaker that never opened and one that never closed both
/// still return an answer.
///
/// The explicit subscription is redundant with `recommend`'s own — it is here
/// because this test reaches the model directly through `guarded`, and reading
/// as though a breaker test needed no entitlement would be a trap for whoever
/// next adds a case to it.
#[tokio::test]
async fn the_breaker_trips_and_then_recovers() {
    let db = TestDatabase::create("assistant_breaker").await;
    subscribe_to_coach(&db, USER).await;

    let model = ScriptedModel::script(vec![
        Err(ModelError::Failed("first".to_owned())),
        Err(ModelError::Failed("second".to_owned())),
        Err(ModelError::Failed("third".to_owned())),
        Ok("box-breathing | Back up.".to_owned()),
    ]);
    // Three failures to trip, and a cooldown short enough to wait out inside a
    // test — the production policy is a minute, which is not a thing to sleep
    // through here.
    let guarded = Arc::new(GuardedModelClient::with_policy(
        model.clone(),
        3,
        Duration::from_millis(150),
    ));

    for _ in 0..3 {
        let response = recommend(&db, guarded.clone(), USER).await;
        assert_eq!(response.source, pb::AssistantSource::Fallback as i32);
    }
    assert_eq!(model.calls(), 3, "three failures reach the model");

    let while_open = recommend(&db, guarded.clone(), USER).await;
    assert_eq!(while_open.source, pb::AssistantSource::Fallback as i32);
    assert_eq!(
        model.calls(),
        3,
        "the fourth call is refused without reaching the model"
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    let recovered = recommend(&db, guarded, USER).await;
    assert_eq!(recovered.source, pb::AssistantSource::Model as i32);
    assert_eq!(model.calls(), 4, "the cooldown lets one call through");
}

/// The repo's first server-streaming RPC, over the real gRPC-Web framing: the
/// chunks arrive as separate message frames, in order, and concatenate back
/// into what the model wrote. A client accumulates them, so order is the whole
/// contract.
#[tokio::test]
async fn the_explanation_streams_ordered_chunks() {
    let db = TestDatabase::create("assistant_streaming").await;
    let model = ScriptedModel::always(Ok("First the mechanism.\n\
         Then what it does to you.\n\
         Then when to reach for it."
        .to_owned()));

    let chunks = explain(&db, model, USER, "box-breathing").await.into_ok();

    assert!(
        chunks.len() > 1,
        "a stream that arrived as one frame is not streaming"
    );
    for chunk in &chunks {
        assert_eq!(chunk.source, pb::AssistantSource::Model as i32);
    }

    let text: String = chunks
        .iter()
        .map(|chunk| chunk.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(
        text,
        "First the mechanism.\nThen what it does to you.\nThen when to reach for it."
    );
}

/// With no model, the same RPC still answers — in chunks, on the same path, so
/// the client's accumulate-and-render code is exercised whether or not a
/// provider was reachable.
#[tokio::test]
async fn an_unavailable_model_still_explains() {
    let db = TestDatabase::create("assistant_streaming_fallback").await;
    let model = ScriptedModel::always(Err(ModelError::Failed("down".to_owned())));

    let chunks = explain(&db, model, USER, "wim-hof-rounds").await.into_ok();

    assert!(
        chunks.len() > 1,
        "the fallback goes down the same chunked path, so the client's \
         accumulate-and-render code is exercised whether or not a model answered"
    );
    for chunk in &chunks {
        assert_eq!(chunk.source, pb::AssistantSource::Fallback as i32);
    }

    let text: String = chunks.iter().map(|chunk| chunk.text.as_str()).collect();
    assert!(
        text.contains("water"),
        "the fallback carries the technique's safety note, which for this one is not optional"
    );
}

/// A slug the catalogue does not hold is `NOT_FOUND`, not an explanation of
/// something that does not exist. The model is never asked, which is the point:
/// the check is before the spend, not after it.
#[tokio::test]
async fn an_unknown_technique_is_not_explained() {
    let db = TestDatabase::create("assistant_unknown_technique").await;
    let model = ScriptedModel::always(Ok("anything".to_owned()));

    let response = explain(&db, model.clone(), USER, "moon-breathing").await;

    assert_eq!(response.status, tonic::Code::NotFound as i32);
    assert_eq!(model.calls(), 0);
}

/// Both RPCs are scoped to a person, so a caller with no identity gets
/// `UNAUTHENTICATED` rather than somebody else's guidance.
#[tokio::test]
async fn guidance_requires_an_identity() {
    let db = TestDatabase::create("assistant_identity").await;

    let anonymous: crate::harness::GrpcWebResponse<pb::GetRecommendationResponse> =
        call_grpc_web_with(
            db.app(),
            GET_RECOMMENDATION,
            &pb::GetRecommendationRequest {},
            &[],
        )
        .await;
    assert_eq!(anonymous.status, tonic::Code::Unauthenticated as i32);

    let streamed = call_grpc_web_stream_with::<_, pb::ExplainTechniqueResponse>(
        db.app(),
        EXPLAIN_TECHNIQUE,
        &pb::ExplainTechniqueRequest {
            technique_slug: "box-breathing".to_owned(),
        },
        &[],
    )
    .await;
    assert_eq!(streamed.status, tonic::Code::Unauthenticated as i32);
    assert!(streamed.messages.is_empty());
}

/// One person's spend and one person's answers stay theirs. The other caller
/// has different goals, so the rules rank differently — which is what proves
/// the profile was read per caller rather than once.
#[tokio::test]
async fn callers_do_not_share_guidance() {
    let db = TestDatabase::create("assistant_isolation").await;
    set_goals(&db, USER, &[pb::TechniqueGoal::Sleep]).await;
    set_goals(&db, OTHER_USER, &[pb::TechniqueGoal::Energy]).await;

    let model = ScriptedModel::always(Err(ModelError::Failed("down".to_owned())));

    let mine = recommend(&db, model.clone(), USER).await;
    let theirs = recommend(&db, model, OTHER_USER).await;

    assert_ne!(
        mine.recommendations[0].technique_slug,
        theirs.recommendations[0].technique_slug
    );
}

/// The one test that spends money.
///
/// `#[ignore]` and named `smoke_*`, which is the category `mise run
/// assistant:smoke` runs and nothing else does — so it never runs in `mise run
/// test:e2e` or in CI. It is the only way to find out whether the key, the model
/// id, the request body, and the parser agree with a provider that is not a test
/// double. Everything above this line is deterministic; this is the seam's other
/// side, and it can only be checked by calling it.
///
/// Skips rather than fails without a key, because "no key" is a supported state
/// of this repo and not a broken smoke test.
#[tokio::test]
#[ignore = "calls the real model provider; run it with `mise run assistant:smoke`"]
// The whole output of this test is what it printed — a status line nobody reads
// is not a smoke test.
#[allow(clippy::print_stdout)]
async fn smoke_the_real_model_answers() {
    let Some(key) = std::env::var("OPENROUTER_API_KEY")
        .ok()
        .filter(|key| !key.trim().is_empty())
    else {
        println!("OPENROUTER_API_KEY is not set — nothing to smoke-test");
        return;
    };

    let client = api::assistant::OpenRouterClient::new(&key).expect("the HTTP client builds");

    let db = TestDatabase::create("assistant_smoke").await;
    set_goals(&db, USER, &[pb::TechniqueGoal::Sleep]).await;

    let response = recommend(&db, Arc::new(client), USER).await;

    println!("model:  {}", api::config::OPENROUTER_MODEL_ID);
    println!(
        "source: {:?}",
        pb::AssistantSource::try_from(response.source)
    );
    for item in &response.recommendations {
        let reason: String = item.reason.chars().take(90).collect();
        println!("  {} — {reason}", item.technique_slug);
    }

    assert_eq!(
        response.source,
        pb::AssistantSource::Model as i32,
        "the provider answered but the reply was unusable — see the warning above"
    );
}

/// Asks for a recommendation as somebody who is allowed to reach the model.
///
/// The subscription is part of the helper rather than repeated at the top of
/// every test, because this suite is about what the model says and not about
/// who may ask it — that gate is `entitlement.rs`'s, and a test here that forgot
/// the setup would fail as though the assistant were broken. Cheap enough to
/// repeat: it is one upsert per call.
async fn recommend(
    db: &TestDatabase,
    model: Arc<dyn ModelClient>,
    user: &str,
) -> pb::GetRecommendationResponse {
    subscribe_to_coach(db, user).await;

    call_grpc_web_with(
        db.app_with_model(model),
        GET_RECOMMENDATION,
        &pb::GetRecommendationRequest {},
        &[(USER_ID_HEADER, user)],
    )
    .await
    .into_ok()
}

async fn explain(
    db: &TestDatabase,
    model: Arc<dyn ModelClient>,
    user: &str,
    slug: &str,
) -> crate::harness::GrpcWebStream<pb::ExplainTechniqueResponse> {
    subscribe_to_coach(db, user).await;

    call_grpc_web_stream_with(
        db.app_with_model(model),
        EXPLAIN_TECHNIQUE,
        &pb::ExplainTechniqueRequest {
            technique_slug: slug.to_owned(),
        },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

/// Puts somebody on Coach by writing the columns `EntitlementService` writes.
///
/// Straight into the row rather than through a submission, because this suite
/// scripts no verifier and the only thing it wants from a subscription is
/// permission to reach the model. Who is allowed to buy that permission, and
/// what a real purchase does to those columns, is `entitlement.rs`'s business.
async fn subscribe_to_coach(db: &TestDatabase, user: &str) {
    sqlx::query(
        "INSERT INTO users (id, subscription_tier, subscription_until)
         VALUES ($1, 'COACH', now() + interval '1 year')
         ON CONFLICT (id) DO UPDATE SET
           subscription_tier = EXCLUDED.subscription_tier,
           subscription_until = EXCLUDED.subscription_until",
    )
    .bind(user.parse::<uuid::Uuid>().expect("a valid uuid"))
    .execute(&db.pool)
    .await
    .expect("the subscription is written");
}

/// Stores goals through the real `ProfileService`, so the rows the assistant
/// reads are the ones onboarding writes.
async fn set_goals(db: &TestDatabase, user: &str, goals: &[pb::TechniqueGoal]) {
    let response: crate::harness::GrpcWebResponse<pb::UpdateProfileResponse> = call_grpc_web_with(
        db.app(),
        "/breathe.v1.ProfileService/UpdateProfile",
        &pb::UpdateProfileRequest {
            profile: Some(pb::Profile {
                goals: goals.iter().map(|goal| *goal as i32).collect(),
                experience_level: pb::ExperienceLevel::New as i32,
                ..pb::Profile::default()
            }),
        },
        &[(USER_ID_HEADER, user)],
    )
    .await;

    response.into_ok();
}
