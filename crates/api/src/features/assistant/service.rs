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
use super::model::{ChatRole, ChatTurn, ModelClient, ModelRequest};
use super::types::{
    CHAT_MAX_TOKENS, EXPLANATION_MAX_TOKENS, HealthContext, MAX_CHAT_MESSAGE_CHARS, MAX_CHAT_TURNS,
    RECOMMENDATION_MAX_TOKENS, Recommendation, daily_model_calls,
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
use crate::proto::ond::v1 as pb;

/// What the `ExplainTechnique` handler returns to tonic.
pub type ExplanationStream =
    Pin<Box<dyn Stream<Item = Result<pb::ExplainTechniqueResponse, tonic::Status>> + Send>>;

/// What the `Chat` handler returns to tonic.
pub type ChatStream = Pin<Box<dyn Stream<Item = Result<pb::ChatResponse, tonic::Status>> + Send>>;

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
    health: Option<pb::HealthContext>,
) -> Result<pb::GetRecommendationResponse, AssistantError> {
    let context = read_context(pool, user_id).await?;
    if context.catalogue.is_empty() {
        return Err(AssistantError::EmptyCatalogue);
    }

    let health = clamp_health(health);
    let (recommendations, source) =
        match model_recommendations(pool, model, user_id, &context, health.as_ref()).await {
            Some(recommendations) => (recommendations, pb::AssistantSource::Model),
            None => (
                fallback::recommendations(&context.catalogue, &context.profile, &context.practice),
                pb::AssistantSource::Fallback,
            ),
        };

    Ok(pb::GetRecommendationResponse {
        recommendations: recommendations.into_iter().map(to_proto).collect(),
        source: source as i32,
    })
}

/// Everything an RPC here reads before deciding anything: the catalogue, the
/// caller's profile, their recent practice, and what they are entitled to.
///
/// One struct rather than a tuple because three RPCs now thread it whole, and
/// a four-way tuple at three call sites is four positional facts nobody can
/// name at a glance.
struct Context {
    catalogue: Vec<Technique>,
    profile: ProfileSnapshot,
    practice: PracticeSnapshot,
    tier: Tier,
}

/// Reads the [`Context`], concurrently.
///
/// Concurrently because none of the four reads depends on the others, and all
/// of them happen before anything else can: serialising them would put four
/// loopback round-trips in front of every call rather than one. The
/// entitlement joins them rather than being read where it is used, for exactly
/// that reason — it decides the model allowance, which is the last thing any
/// RPC settles.
async fn read_context(pool: &PgPool, user_id: UserId) -> Result<Context, AssistantError> {
    let (catalogue, profile, practice, tier) = tokio::try_join!(
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
    )?;

    Ok(Context {
        catalogue,
        profile,
        practice,
        tier,
    })
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
    context: &Context,
    health: Option<&HealthContext>,
) -> Option<Vec<Recommendation>> {
    if !model.is_available() || !claim_call(pool, user_id, context.tier).await {
        return None;
    }

    let request = ModelRequest {
        cacheable_prefix: prompt::catalogue_prefix(&context.catalogue),
        instruction: prompt::recommendation_instruction(
            &context.profile,
            &context.practice,
            &context.catalogue,
            health,
        ),
        turns: Vec::new(),
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
    let recommendations = parse::parse_recommendations(&reply, &context.catalogue);
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
    health: Option<pb::HealthContext>,
) -> Result<ExplanationStream, AssistantError> {
    let context = read_context(pool, user_id).await?;
    let technique = resolve(&context.catalogue, slug).ok_or_else(|| {
        AssistantError::UnknownTechnique(format!("no technique has the slug `{slug}`"))
    })?;

    let health = clamp_health(health);

    // Availability first, so a process with no key configured — a fresh clone,
    // CI, the whole e2e suite — neither writes a quota row nor builds a prompt
    // for a call that provably will not be made.
    if model.is_available() && claim_call(pool, user_id, context.tier).await {
        let request = ModelRequest {
            cacheable_prefix: prompt::catalogue_prefix(&context.catalogue),
            instruction: prompt::explanation_instruction(
                technique,
                &context.profile,
                &context.practice,
                &context.catalogue,
                health.as_ref(),
            ),
            turns: Vec::new(),
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
        &context.profile,
        context.practice.bolt.as_ref(),
    )))
}

/// The coach's reply to one message in a conversation, streamed a chunk at a
/// time.
///
/// Stateless on purpose: the transcript lives on the device and arrives as
/// `history`, the server keeps and logs none of it, and the only thing this
/// call writes anywhere is the quota claim. Falls back on the same terms as
/// the other two RPCs — every failure short of a malformed request streams the
/// fixed [`fallback::CHAT_REPLY`] flagged `FALLBACK` — and a model that fails
/// *mid-answer* ends the stream `UNAVAILABLE`, exactly as
/// [`explain_technique`] does and for the same reason.
pub async fn chat(
    pool: &PgPool,
    model: &dyn ModelClient,
    user_id: UserId,
    history: Vec<pb::ChatTurn>,
    message: &str,
    health: Option<pb::HealthContext>,
) -> Result<ChatStream, AssistantError> {
    // Shape first, so a malformed request is refused before it writes a quota
    // row or reads anything at all.
    let turns = conversation(history, message)?;

    // Unlike the explanation's fallback, the fixed reply needs nothing from
    // the database — so a process with no key, or an open breaker, answers
    // before any of the four context reads happen.
    if !model.is_available() {
        return Ok(fixed_reply());
    }

    let context = read_context(pool, user_id).await?;
    let health = clamp_health(health);

    if claim_call(pool, user_id, context.tier).await {
        let request = ModelRequest {
            cacheable_prefix: prompt::catalogue_prefix(&context.catalogue),
            instruction: prompt::chat_instruction(
                &context.profile,
                &context.practice,
                &context.catalogue,
                health.as_ref(),
            ),
            turns,
            max_tokens: CHAT_MAX_TOKENS,
        };

        match model.stream(&request).await {
            Ok(chunks) => return Ok(chat_from_model(chunks)),
            Err(error) => {
                tracing::warn!(feature = "assistant", %error, "falling back to the fixed reply");
            }
        }
    }

    Ok(fixed_reply())
}

/// The fixed [`fallback::CHAT_REPLY`] as a one-chunk stream, flagged
/// `FALLBACK`.
fn fixed_reply() -> ChatStream {
    Box::pin(tokio_stream::iter(vec![Ok(pb::ChatResponse {
        text: fallback::CHAT_REPLY.to_owned(),
        source: pb::AssistantSource::Fallback as i32,
    })]))
}

/// The wire history and the new message as the turns the model seam carries,
/// bounded and attributed — or the `INVALID_ARGUMENT` that refuses the call.
///
/// Two different bounds, deliberately asymmetric. Length is a *bound*: an
/// over-long message or turn is refused, because trimming one mid-sentence
/// would have the coach answer something the person did not say. History depth
/// is a *truncation*: only the newest [`MAX_CHAT_TURNS`] are kept, silently,
/// because a transcript's length is the app's doing rather than the person's
/// and refusing them for it would answer nothing. Dropped turns are dropped
/// before validation — a malformed turn that no longer participates cannot
/// fail the request.
fn conversation(
    history: Vec<pb::ChatTurn>,
    message: &str,
) -> Result<Vec<ChatTurn>, AssistantError> {
    let message = message.trim();
    if message.is_empty() {
        return Err(AssistantError::InvalidChat(
            "the message is empty".to_owned(),
        ));
    }
    if message.chars().count() > MAX_CHAT_MESSAGE_CHARS {
        return Err(AssistantError::InvalidChat(format!(
            "the message exceeds {MAX_CHAT_MESSAGE_CHARS} characters"
        )));
    }

    let newest = history.len().saturating_sub(MAX_CHAT_TURNS);
    let mut turns: Vec<ChatTurn> = history
        .into_iter()
        .skip(newest)
        .map(|turn| {
            if turn.text.chars().count() > MAX_CHAT_MESSAGE_CHARS {
                return Err(AssistantError::InvalidChat(format!(
                    "a history turn exceeds {MAX_CHAT_MESSAGE_CHARS} characters"
                )));
            }
            let role = match turn.role() {
                pb::ChatRole::Person => ChatRole::Person,
                pb::ChatRole::Coach => ChatRole::Coach,
                pb::ChatRole::Unspecified => {
                    return Err(AssistantError::InvalidChat(
                        "a history turn does not say who spoke".to_owned(),
                    ));
                }
            };
            Ok(ChatTurn {
                role,
                text: turn.text,
            })
        })
        .collect::<Result<_, _>>()?;

    turns.push(ChatTurn {
        role: ChatRole::Person,
        text: message.to_owned(),
    });
    Ok(turns)
}

/// [`model_chunks`] for the chat wire type.
fn chat_from_model(chunks: super::model::ModelStream) -> ChatStream {
    model_chunks(chunks, "the reply stopped early", |text| pb::ChatResponse {
        text,
        source: pb::AssistantSource::Model as i32,
    })
}

/// Maps the model's chunks onto a wire type, one rule for every streaming RPC.
///
/// A chunk that fails mid-answer ends the stream rather than replacing what has
/// already been read: the person is looking at half an answer, and switching to
/// the fallback text at that point would contradict the sentence above it. It
/// ends with `UNAVAILABLE` rather than simply stopping, because a stream that
/// stops is indistinguishable from one that finished — the client would caption
/// a truncated answer as the whole of it. tonic ends the response at the first
/// `Err`, so nothing the provider sends after the failure can follow the status
/// onto the wire.
///
/// Generic over the wire constructor so the rule has one owner; `stopped` is
/// each RPC's own phrasing of it, logged and sent alike.
fn model_chunks<T>(
    chunks: super::model::ModelStream,
    stopped: &'static str,
    wire: impl Fn(String) -> T + Send + 'static,
) -> Pin<Box<dyn Stream<Item = Result<T, tonic::Status>> + Send>> {
    Box::pin(chunks.map(move |chunk| match chunk {
        Ok(text) => Ok(wire(text)),
        Err(error) => {
            tracing::warn!(feature = "assistant", %error, "{stopped}");
            Err(tonic::Status::unavailable(stopped))
        }
    }))
}

/// [`model_chunks`] for the explanation wire type.
fn from_model(chunks: super::model::ModelStream) -> ExplanationStream {
    model_chunks(chunks, "the explanation stopped early", |text| {
        pb::ExplainTechniqueResponse {
            text,
            source: pb::AssistantSource::Model as i32,
        }
    })
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

/// The wire health context as the domain type, clamped, or `None` when
/// nothing usable was sent.
///
/// This is the only place the wire message is read, and the value it produces
/// lives exactly as long as the call: nothing here or downstream persists it,
/// and nothing formats it — the domain type deliberately cannot be (see
/// [`HealthContext`]). The wire message itself derives `Debug` like every
/// prost type, so it must never be handed to `tracing` either; keeping the
/// conversion at the top of each RPC keeps its scope one screen tall.
fn clamp_health(health: Option<pb::HealthContext>) -> Option<HealthContext> {
    health.and_then(|context| {
        HealthContext::clamped(
            context.resting_hr_bpm,
            context.resting_hr_trend_bpm,
            context.hrv_sdnn_ms,
            context.hrv_sdnn_trend_ms,
        )
    })
}

fn to_proto(recommendation: Recommendation) -> pb::Recommendation {
    pb::Recommendation {
        technique_slug: recommendation.technique_slug,
        reason: recommendation.reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire_turn(role: pb::ChatRole, text: &str) -> pb::ChatTurn {
        pb::ChatTurn {
            role: role as i32,
            text: text.to_owned(),
        }
    }

    /// Truncation keeps the newest turns and always appends the message: the
    /// end of a conversation is what the next answer hangs on, and the person
    /// asked their question last.
    #[test]
    fn truncation_keeps_the_newest_turns_and_ends_on_the_message() {
        let history: Vec<pb::ChatTurn> = (0..MAX_CHAT_TURNS + 5)
            .map(|index| wire_turn(pb::ChatRole::Person, &format!("turn-{index}")))
            .collect();

        let turns = conversation(history, "the question").expect("a valid conversation");

        assert_eq!(turns.len(), MAX_CHAT_TURNS + 1, "history plus the message");
        assert_eq!(turns[0].text, "turn-5", "the oldest five are dropped");
        let last = turns.last().expect("the message is appended");
        assert_eq!(last.text, "the question");
        assert_eq!(last.role, ChatRole::Person);
    }

    /// The length rule is a bound, not a trim: the edge passes whole and one
    /// character past it refuses the call, for the message and for a history
    /// turn alike.
    #[test]
    fn the_character_bound_refuses_rather_than_trims() {
        let longest = "x".repeat(MAX_CHAT_MESSAGE_CHARS);
        let over = "x".repeat(MAX_CHAT_MESSAGE_CHARS + 1);

        assert!(conversation(Vec::new(), &longest).is_ok());
        assert!(matches!(
            conversation(Vec::new(), &over),
            Err(AssistantError::InvalidChat(_))
        ));
        assert!(matches!(
            conversation(vec![wire_turn(pb::ChatRole::Coach, &over)], "hello"),
            Err(AssistantError::InvalidChat(_))
        ));
    }

    /// An empty message — including one that is only whitespace — is a client
    /// bug, refused rather than answered with a reply to nothing.
    #[test]
    fn an_empty_message_is_refused() {
        assert!(matches!(
            conversation(Vec::new(), "   "),
            Err(AssistantError::InvalidChat(_))
        ));
    }

    /// A turn that does not name its speaker cannot be handed to the model as
    /// attributed speech, so it fails the request — unless truncation already
    /// dropped it, in which case it no longer participates and cannot.
    #[test]
    fn an_unattributed_turn_fails_only_while_it_participates() {
        assert!(matches!(
            conversation(
                vec![wire_turn(pb::ChatRole::Unspecified, "who said this")],
                "hello"
            ),
            Err(AssistantError::InvalidChat(_))
        ));

        let mut history = vec![wire_turn(pb::ChatRole::Unspecified, "who said this")];
        history.extend(
            (0..MAX_CHAT_TURNS).map(|index| wire_turn(pb::ChatRole::Person, &format!("{index}"))),
        );
        assert!(
            conversation(history, "hello").is_ok(),
            "a dropped turn cannot fail the request"
        );
    }
}
