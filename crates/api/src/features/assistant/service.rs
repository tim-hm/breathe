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
use uuid::Uuid;

use super::errors::AssistantError;
use super::model::{ModelClient, ModelRequest};
use super::types::{
    DAILY_MODEL_CALLS, EXPLANATION_MAX_TOKENS, RECOMMENDATION_MAX_TOKENS, Recommendation,
};
use super::{fallback, parse, prompt, repository};
use crate::features::profile::repository::{ProfileRow, find_profile};
use crate::features::technique::repository::{TechniqueRow, list_techniques};
use crate::proto::breathe::v1 as pb;

/// What the `ExplainTechnique` handler returns to tonic.
pub type ExplanationStream =
    Pin<Box<dyn Stream<Item = Result<pb::ExplainTechniqueResponse, tonic::Status>> + Send>>;

pub async fn get_recommendation(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: Uuid,
) -> Result<pb::GetRecommendationResponse, AssistantError> {
    let (catalogue, profile) = read_context(pool, user_id).await?;
    if catalogue.is_empty() {
        return Err(AssistantError::EmptyCatalogue);
    }

    let (recommendations, source) =
        match model_recommendations(pool, model, user_id, &catalogue, &profile).await {
            Some(recommendations) => (recommendations, pb::AssistantSource::Model),
            None => (
                fallback::recommendations(&catalogue, &profile),
                pb::AssistantSource::Fallback,
            ),
        };

    Ok(pb::GetRecommendationResponse {
        recommendations: recommendations.into_iter().map(to_proto).collect(),
        source: source as i32,
    })
}

/// The catalogue and the caller's profile, read together.
///
/// Concurrently because neither read depends on the other, and both happen
/// before anything else can: serialising them would put two loopback
/// round-trips in front of every call rather than one.
async fn read_context(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<(Vec<TechniqueRow>, ProfileRow), AssistantError> {
    let (catalogue, profile) = tokio::try_join!(
        async { list_techniques(pool).await.map_err(AssistantError::from) },
        async {
            find_profile(pool, user_id)
                .await
                .map_err(AssistantError::from)
        },
    )?;

    Ok((catalogue, profile))
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
    user_id: Uuid,
    catalogue: &[TechniqueRow],
    profile: &ProfileRow,
) -> Option<Vec<Recommendation>> {
    if !model.is_available() || !claim_call(pool, user_id).await {
        return None;
    }

    let request = ModelRequest {
        cacheable_prefix: prompt::catalogue_prefix(catalogue),
        instruction: prompt::recommendation_instruction(profile),
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

pub async fn explain_technique(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: Uuid,
    slug: &str,
) -> Result<ExplanationStream, AssistantError> {
    let (catalogue, profile) = read_context(pool, user_id).await?;
    let technique = catalogue
        .iter()
        .find(|row| row.slug == slug)
        .ok_or_else(|| {
            AssistantError::UnknownTechnique(format!("no technique has the slug `{slug}`"))
        })?;

    // Availability first, so a process with no key configured — a fresh clone,
    // CI, the whole e2e suite — neither writes a quota row nor builds a prompt
    // for a call that provably will not be made.
    if model.is_available() && claim_call(pool, user_id).await {
        let request = ModelRequest {
            cacheable_prefix: prompt::catalogue_prefix(&catalogue),
            instruction: prompt::explanation_instruction(technique, &profile),
            max_tokens: EXPLANATION_MAX_TOKENS,
        };

        match model.stream(&request).await {
            Ok(chunks) => return Ok(from_model(chunks)),
            Err(error) => {
                tracing::warn!(feature = "assistant", %error, "falling back to the rules");
            }
        }
    }

    Ok(from_fallback(&fallback::explanation(technique, &profile)))
}

/// Maps the model's chunks onto the wire.
///
/// A chunk that fails mid-answer ends the stream rather than replacing what has
/// already been read: the person is looking at half an explanation, and
/// switching to the fallback text at that point would contradict the sentence
/// above it.
fn from_model(chunks: super::model::ModelStream) -> ExplanationStream {
    Box::pin(chunks.map_while(|chunk| match chunk {
        Ok(text) => Some(Ok(pb::ExplainTechniqueResponse {
            text,
            source: pb::AssistantSource::Model as i32,
        })),
        Err(error) => {
            tracing::warn!(feature = "assistant", %error, "the explanation stopped early");
            None
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
/// A database failure here reads as "no allowance". The alternative — failing
/// the whole RPC — would take the fallback down with the counter, and the
/// fallback is the thing that is supposed to survive.
async fn claim_call(pool: &PgPool, user_id: Uuid) -> bool {
    match repository::claim_daily_call(pool, user_id, DAILY_MODEL_CALLS).await {
        Ok(claimed) => {
            if !claimed {
                tracing::info!(
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
