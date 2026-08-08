//! The seam every language model sits behind.
//!
//! One trait, three implementations: `super::bedrock` calls a provider,
//! [`DisabledModelClient`] calls nothing, and the integration tests script one.
//! Everything else in this feature — quota, circuit breaker, validation,
//! fallback — is written against the trait, so all of it is exercised without a
//! network call and the only untested code is the thin layer that builds a
//! request body.
//!
//! The vocabulary is deliberately not a provider's. A `ModelRequest` is a
//! cacheable prefix, an instruction, and a ceiling; how that becomes a Messages
//! API call is `bedrock`'s business.

pub mod bedrock;
pub mod breaker;
pub mod disabled;

use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tokio_stream::Stream;

use self::bedrock::BedrockClient;
use self::breaker::GuardedModelClient;
use self::disabled::DisabledModelClient;
use crate::config::Environment;

/// Text arriving a piece at a time, in order.
///
/// Boxed rather than an associated type because the trait is used through
/// `dyn`: the composition root chooses the implementation at startup, so the
/// concrete stream type is not known at any call site.
pub type ModelStream = Pin<Box<dyn Stream<Item = Result<String, ModelError>> + Send>>;

/// Who spoke one turn of a conversation, in the seam's own vocabulary.
///
/// Two variants and no "unspecified": a wire turn that does not name its
/// speaker is rejected at the boundary, so nothing behind it has to carry the
/// doubt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatRole {
    /// The person using the app.
    Person,
    /// The coach's own earlier reply, read back to it.
    Coach,
}

/// One turn of a conversation, ready for a provider to render as genuinely
/// attributed speech.
///
/// Real roles rather than a transcript serialised into the instruction, on
/// purpose: a provider renders these as actual user/assistant messages, and an
/// instruction smuggled into a turn arrives marked as somebody's speech rather
/// than as the caller's authority — materially harder to inject through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatTurn {
    pub role: ChatRole,
    pub text: String,
}

/// One call's worth of prompt, split where the cache boundary goes.
pub struct ModelRequest {
    /// Everything identical from one call to the next — the system prompt and
    /// the serialized catalogue. Held separately because the provider caches
    /// this prefix and bills a fraction for it on subsequent calls, and a
    /// prefix that varied per request would never be read back.
    pub cacheable_prefix: String,

    /// The part that differs per caller: their profile, or the technique they
    /// asked about. Always after the prefix, for the same reason.
    pub instruction: String,

    /// The conversation, oldest first, ending on the person's newest message.
    /// Empty for the one-shot RPCs, whose whole ask fits in `instruction`.
    pub turns: Vec<ChatTurn>,

    /// The output ceiling. Small on purpose — every response here is a handful
    /// of sentences, and a ceiling is the only cost control that binds even
    /// when the prompt does not.
    pub max_tokens: i32,
}

/// Why a model call did not produce an answer.
///
/// Two variants because the circuit breaker has to tell its own refusals apart
/// from real failures: counting an `Unavailable` as another failure would keep
/// re-arming the breaker for as long as it stayed open, and it would never
/// close.
#[derive(Debug, thiserror::Error)]
pub enum ModelError {
    /// The call was never attempted — the breaker is open.
    #[error("the model is not being called: {0}")]
    Unavailable(String),

    /// The call was attempted and failed: unreachable, throttled, refused, or
    /// malformed. Counts against the breaker.
    #[error("the model call failed: {0}")]
    Failed(String),
}

impl ModelError {
    /// The answer a client gives when it declines to call anything.
    ///
    /// One constructor rather than one per implementation, so "the disabled
    /// client answers exactly what the breaker answers" is a fact about the
    /// code rather than a claim in a comment.
    pub fn unavailable(reason: &str) -> Self {
        Self::Unavailable(reason.to_owned())
    }
}

/// What the assistant needs from a language model, and nothing else.
///
/// `tonic::async_trait` rather than a native `async fn`: async functions in
/// traits are not `dyn`-compatible, and this trait exists to be used through
/// `dyn`. tonic re-exports the macro, so this costs no dependency.
#[tonic::async_trait]
pub trait ModelClient: Send + Sync {
    /// The whole reply, once. Used where the answer is parsed before anyone
    /// sees it — a ranked list is not useful half-arrived.
    async fn complete(&self, request: &ModelRequest) -> Result<String, ModelError>;

    /// The reply as it is written. The `Result` is the call being *established*;
    /// a failure after the first chunk arrives on the stream instead.
    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError>;

    /// Whether a call would be attempted at all, asked before one is prepared.
    ///
    /// Purely advisory and deliberately not authoritative — `complete` and
    /// `stream` still refuse on their own, because the breaker can trip between
    /// this answer and the call. What it buys is that the caller can skip the
    /// work a refusal would waste: a quota claim, which is a database write, and
    /// the prompt, which walks the whole catalogue. Where no AWS credentials
    /// resolved that is every request in the process.
    ///
    /// Defaulted to `true` so an implementation that always tries — the
    /// provider, a test double — says nothing.
    fn is_available(&self) -> bool {
        true
    }
}

/// A duration as the `duration_ms` field `docs/observability.md` fixes by
/// convention.
///
/// Saturating rather than fallible: a duration too large for a `u64` of
/// milliseconds is a broken clock, and losing the line to it would hide the
/// outage the line was written to explain.
fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// Installs the model client this process will use.
///
/// Two outcomes, and both are normal:
///
/// - **AWS credentials resolve** — Bedrock, behind the circuit breaker. On the
///   box those credentials are the instance profile, reached over the metadata
///   endpoint; on a developer's machine they are whatever `AWS_PROFILE` names.
/// - **They do not** — [`DisabledModelClient`], which is not a degraded mode so
///   much as the app's offline-first promise applied at boot: every RPC still
///   answers, from the rules, flagged `FALLBACK`. That is what lets a fresh
///   clone run `mise run dev` and the integration tests run in CI with no AWS
///   identity at all.
///
/// Nothing about *which* model is configurable — region and model are
/// constants, and the credentials are found rather than supplied. The
/// environment is taken for one reason, which is the level the second outcome is
/// logged at: on a laptop or a CI runner it is the supported state this repo
/// documents, and on the box the same line means the coach is down. Async only
/// because finding credentials is.
///
/// One log line either way, because "the assistant is quiet today" is otherwise
/// indistinguishable from "this machine cannot sign for Bedrock" from outside
/// the process.
pub async fn install(environment: Environment) -> Arc<dyn ModelClient> {
    // One message, logged at two levels below. `tracing` takes its level as a
    // compile-time constant, so the level cannot be a variable and the two calls
    // cannot share a literal without this.
    const QUIET: &str =
        "the assistant cannot reach Bedrock — answering from the rule-based fallback";

    let error = match BedrockClient::connect().await {
        Ok(client) => {
            tracing::info!(
                feature = "assistant",
                model = crate::config::BEDROCK_MODEL_ID,
                region = crate::config::BEDROCK_REGION,
                "the assistant is live"
            );
            return Arc::new(GuardedModelClient::new(Arc::new(client)));
        }
        Err(error) => error,
    };

    // On a laptop or a CI runner this is the supported state docs/deployment.md
    // describes; on the box it is the coach being down, and only one of those is
    // worth a `warn`. A match on `Environment` rather than a bool, which is the
    // convention config.rs sets for everything that differs between the two.
    match environment {
        Environment::Production => tracing::warn!(feature = "assistant", %error, "{QUIET}"),
        Environment::Dev => tracing::info!(feature = "assistant", %error, "{QUIET}"),
    }

    Arc::new(DisabledModelClient)
}
