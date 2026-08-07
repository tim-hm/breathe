//! The seam every language model sits behind.
//!
//! One trait, three implementations: `super::openrouter` calls a provider,
//! [`DisabledModelClient`] calls nothing, and the integration tests script one.
//! Everything else in this feature — quota, circuit breaker, validation,
//! fallback — is written against the trait, so all of it is exercised without a
//! network call and the only untested code is the thin layer that builds an
//! HTTP body.
//!
//! The vocabulary is deliberately not a provider's. A `ModelRequest` is a
//! cacheable prefix, an instruction, and a ceiling; how that becomes a
//! chat-completions call is `openrouter`'s business.

pub mod breaker;
pub mod disabled;
pub mod openrouter;

use std::pin::Pin;
use std::sync::Arc;

use tokio_stream::Stream;

use self::breaker::GuardedModelClient;
use self::disabled::DisabledModelClient;
use self::openrouter::OpenRouterClient;
use crate::config::Config;

/// Text arriving a piece at a time, in order.
///
/// Boxed rather than an associated type because the trait is used through
/// `dyn`: the composition root chooses the implementation at startup, so the
/// concrete stream type is not known at any call site.
pub type ModelStream = Pin<Box<dyn Stream<Item = Result<String, ModelError>> + Send>>;

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
    /// the prompt, which walks the whole catalogue. With no key configured that
    /// is every request in the process.
    ///
    /// Defaulted to `true` so an implementation that always tries — the
    /// provider, a test double — says nothing.
    fn is_available(&self) -> bool {
        true
    }
}

/// Installs the model client this process will use.
///
/// Two outcomes, and both are normal:
///
/// - **A key is configured** — `OpenRouter`, behind the circuit breaker.
/// - **No key** — [`DisabledModelClient`], which is not a degraded mode so much
///   as the app's offline-first promise applied at boot: every RPC still
///   answers, from the rules, flagged `FALLBACK`. That is what lets a fresh
///   clone run `mise run dev` and the integration tests run in CI with no
///   secret at all.
///
/// One log line either way, because "the assistant is quiet today" is otherwise
/// indistinguishable from "the key is missing" from outside the process.
pub fn from_config(config: &Config) -> Arc<dyn ModelClient> {
    let Some(key) = config.openrouter_api_key.as_deref() else {
        tracing::info!(
            feature = "assistant",
            "OPENROUTER_API_KEY is not set — answering from the rule-based fallback"
        );
        return Arc::new(DisabledModelClient);
    };

    let Some(client) = OpenRouterClient::new(key) else {
        tracing::error!(
            feature = "assistant",
            "the HTTP client could not be built — answering from the rule-based fallback"
        );
        return Arc::new(DisabledModelClient);
    };

    tracing::info!(
        feature = "assistant",
        model = crate::config::OPENROUTER_MODEL_ID,
        "the assistant is live"
    );
    Arc::new(GuardedModelClient::new(Arc::new(client)))
}
