//! Business logic — decides whether a model is asked at all, checks what it
//! says, and answers regardless.
//!
//! Receives explicit dependencies (`&PgPool`, `&dyn ModelClient`), never
//! `Arc<AppState>`, and contains zero raw queries.
//!
//! Both RPCs run the same three steps, in this order: claim a call against the
//! caller's daily allowance, ask the model, believe as little of the answer as
//! possible. Any step declining hands over to `super::fallback`, and the
//! response says so.

use std::pin::Pin;

use sqlx::PgPool;
use tokio_stream::{Stream, StreamExt as _};

use super::errors::AssistantError;
use super::model::{ModelClient, ModelRequest};
use super::types::{
    EXPLANATION_MAX_TOKENS, RECOMMENDATION_MAX_TOKENS, Recommendation, daily_model_calls,
};
use super::{fallback, parse, prompt, repository};
use crate::features::entitlement::service as entitlement;
use crate::features::entitlement::types::Tier;
use crate::features::journey::sessions::service as journey;
use crate::features::journey::sessions::types::PracticeSnapshot;
use crate::features::profile::service as profile;
use crate::features::profile::types::ProfileSnapshot;
use crate::features::technique::service as technique;
use crate::features::technique::types::{Technique, resolve};
use crate::identity::UserId;
use crate::proto::breathe::v1 as pb;

/// What the `ExplainTechnique` handler returns to tonic.
pub type ExplanationStream =
    Pin<Box<dyn Stream<Item = Result<pb::ExplainTechniqueResponse, tonic::Status>> + Send>>;

/// Three techniques to try next, with a sentence each.
///
/// Always answers. A model that is unconfigured, over quota, behind a tripped
/// breaker, failing, or replying with nothing this server recognises all land on
/// the same rule-based list, and the response's `source` says which arrived — so
/// a client can be honest about it without having to model a failure.
pub async fn get_recommendation(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: UserId,
) -> Result<pb::GetRecommendationResponse, AssistantError> {
    let (catalogue, profile, practice, tier) = read_context(pool, user_id).await?;
    if catalogue.is_empty() {
        return Err(AssistantError::EmptyCatalogue);
    }

    let (recommendations, source) =
        match model_recommendations(pool, model, user_id, tier, &catalogue, &profile, &practice)
            .await
        {
            Some(recommendations) => (recommendations, pb::AssistantSource::Model),
            None => (
                fallback::recommendations(&catalogue, &profile, &practice),
                pb::AssistantSource::Fallback,
            ),
        };

    Ok(pb::GetRecommendationResponse {
        recommendations: recommendations.into_iter().map(to_proto).collect(),
        source: source as i32,
    })
}

/// The catalogue, the caller's profile, their recent practice, and what they
/// are entitled to, read together.
///
/// Concurrently because none of the four depends on the others, and all of them
/// happen before anything else can: serialising them would put four loopback
/// round-trips in front of every call rather than one. The entitlement joins
/// them rather than being read where it is used, for exactly that reason — it
/// decides the model allowance, which is the last thing either RPC settles.
async fn read_context(
    pool: &PgPool,
    user_id: UserId,
) -> Result<(Vec<Technique>, ProfileSnapshot, PracticeSnapshot, Tier), AssistantError> {
    Ok(tokio::try_join!(
        async {
            technique::catalogue(pool)
                .await
                .map_err(AssistantError::from)
        },
        async {
            profile::snapshot(pool, user_id)
                .await
                .map_err(AssistantError::from)
        },
        async {
            journey::practice_snapshot(pool, user_id)
                .await
                .map_err(AssistantError::from)
        },
        async {
            entitlement::tier(pool, user_id)
                .await
                .map_err(AssistantError::from)
        },
    )?)
}

/// The model's answer, or `None` for every reason there might not be one.
///
/// Collapsing "over quota", "breaker open", "call failed", and "reply was
/// unusable" into one `None` is deliberate: the caller does the same thing in
/// all four cases, and a service that branched on them would be four paths
/// where three are untested.
async fn model_recommendations(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: UserId,
    tier: Tier,
    catalogue: &[Technique],
    profile: &ProfileSnapshot,
    practice: &PracticeSnapshot,
) -> Option<Vec<Recommendation>> {
    if !model.is_available() || !claim_call(pool, user_id, tier).await {
        return None;
    }

    let request = ModelRequest {
        cacheable_prefix: prompt::catalogue_prefix(catalogue),
        instruction: prompt::recommendation_instruction(profile, practice, catalogue),
        max_tokens: RECOMMENDATION_MAX_TOKENS,
    };

    let reply = match model.complete(&request).await {
        Ok(reply) => reply,
        Err(error) => {
            tracing::warn!(feature = "assistant", %error, "falling back to the rules");
            return None;
        }
    };

    // The guard: a slug reaches a client only because the catalogue has it.
    let recommendations = parse::parse_recommendations(&reply, catalogue);
    if recommendations.is_empty() {
        tracing::warn!(
            feature = "assistant",
            "the reply named no technique in the catalogue; falling back to the rules"
        );
        return None;
    }

    Some(recommendations)
}

/// Why one technique works, streamed a chunk at a time.
///
/// Answers for any slug the catalogue holds and `NOT_FOUND` for one it does not,
/// which is the only failure a caller can act on. Falls back on the same terms
/// as [`get_recommendation`], and the fallback is chunked down the same pipe so
/// the client has one accumulate-and-render path rather than two.
///
/// A model that fails *mid-answer* ends the stream with `UNAVAILABLE` rather
/// than switching to the fallback text: the person is looking at half an
/// explanation, and a second voice picking up the sentence is worse than a
/// visible stop.
pub async fn explain_technique(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: UserId,
    slug: &str,
) -> Result<ExplanationStream, AssistantError> {
    let (catalogue, profile, practice, tier) = read_context(pool, user_id).await?;
    let technique = resolve(&catalogue, slug).ok_or_else(|| {
        AssistantError::UnknownTechnique(format!("no technique has the slug `{slug}`"))
    })?;

    // Availability first, so a process with no key configured — a fresh clone,
    // CI, the whole e2e suite — neither writes a quota row nor builds a prompt
    // for a call that provably will not be made.
    if model.is_available() && claim_call(pool, user_id, tier).await {
        let request = ModelRequest {
            cacheable_prefix: prompt::catalogue_prefix(&catalogue),
            instruction: prompt::explanation_instruction(
                technique, &profile, &practice, &catalogue,
            ),
            max_tokens: EXPLANATION_MAX_TOKENS,
        };

        match model.stream(&request).await {
            Ok(chunks) => return Ok(from_model(chunks)),
            Err(error) => {
                tracing::warn!(feature = "assistant", %error, "falling back to the rules");
            }
        }
    }

    Ok(from_fallback(&fallback::explanation(
        technique,
        &profile,
        practice.bolt.as_ref(),
    )))
}

/// Maps the model's chunks onto the wire.
///
/// A chunk that fails mid-answer ends the stream rather than replacing what has
/// already been read: the person is looking at half an explanation, and
/// switching to the fallback text at that point would contradict the sentence
/// above it. It ends it with `UNAVAILABLE` rather than simply stopping, because
/// a stream that stops is indistinguishable from one that finished — the client
/// would caption two sentences of a truncated answer as the whole of it.
/// tonic ends the response at the first `Err`, so nothing the provider sends
/// after the failure can follow the status onto the wire.
fn from_model(chunks: super::model::ModelStream) -> ExplanationStream {
    Box::pin(chunks.map(|chunk| match chunk {
        Ok(text) => Ok(pb::ExplainTechniqueResponse {
            text,
            source: pb::AssistantSource::Model as i32,
        }),
        Err(error) => {
            tracing::warn!(feature = "assistant", %error, "the explanation stopped early");
            Err(tonic::Status::unavailable("the explanation stopped early"))
        }
    }))
}

/// Sends the rule-based explanation down the same pipe, a paragraph at a time.
///
/// Chunked rather than sent whole so the client's accumulate-and-render path is
/// the one path — a fallback that arrived as a single message would leave the
/// streaming path exercised only when a model happens to be reachable.
fn from_fallback(text: &str) -> ExplanationStream {
    let chunks: Vec<Result<pb::ExplainTechniqueResponse, tonic::Status>> = text
        .split_inclusive("\n\n")
        .map(|paragraph| {
            Ok(pb::ExplainTechniqueResponse {
                text: paragraph.to_owned(),
                source: pb::AssistantSource::Fallback as i32,
            })
        })
        .collect();

    Box::pin(tokio_stream::iter(chunks))
}

/// Claims one call against the caller's daily allowance.
///
/// `tier` came from the caller's own row, never from the request: this is the
/// only place in the codebase where a client could otherwise talk the server
/// into spending money. It arrives as an argument rather than being read here
/// so the rule ("only Coach, and only so often") stays in Rust where it is
/// testable, instead of inside the `WHERE` clause of the statement below.
///
/// A tier that buys no model calls returns before touching the database. Not an
/// optimisation — a limit of zero would still write the usage row, leaving a
/// table full of people who were never going to be charged against it.
///
/// A database failure here reads as "no allowance". The alternative — failing
/// the whole RPC — would take the fallback down with the counter, and the
/// fallback is the thing that is supposed to survive.
async fn claim_call(pool: &PgPool, user_id: UserId, tier: Tier) -> bool {
    let Some(limit) = daily_model_calls(tier) else {
        return false;
    };

    match repository::claim_daily_call(pool, user_id, limit).await {
        Ok(claimed) => {
            if !claimed {
                // `debug`, not `info`: once somebody is past the ceiling this
                // is every remaining request they make that day, and a heavy
                // user would otherwise be the loudest thing in the log.
                tracing::debug!(
                    feature = "assistant",
                    "the caller has spent today's allowance; answering from the rules"
                );
            }
            claimed
        }
        Err(error) => {
            tracing::error!(feature = "assistant", %error, "could not claim a model call");
            false
        }
    }
}

fn to_proto(recommendation: Recommendation) -> pb::Recommendation {
    pb::Recommendation {
        technique_slug: recommendation.technique_slug,
        reason: recommendation.reason,
    }
}
