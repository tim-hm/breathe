//! Stops calling a model that keeps failing.
//!
//! A decorator rather than a check inside the service: the service already
//! handles "the model did not answer" by falling back, so a breaker that
//! answers `Unavailable` needs no new branch anywhere. It also means the
//! breaker wraps the scripted test double exactly as it wraps the real client,
//! which is
//! how the trip-and-recover behaviour is testable at all.
//!
//! In-process and per-instance. One box serves this app, so a shared breaker
//! would be a Redis dependency bought to coordinate a single process with
//! itself; when there are two boxes, the worst case is each discovering the
//! outage separately.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::model::{ModelClient, ModelError, ModelRequest, ModelStream};

/// Consecutive failures that trip it.
///
/// Consecutive, not a rate: a single timeout is weather, and three in a row
/// with no success between them is the provider being down. Low enough that a
/// real outage costs a handful of slow requests rather than every request for
/// the length of it.
const FAILURES_TO_TRIP: u32 = 3;

/// How long it stays open before letting one call through.
const COOLDOWN: Duration = Duration::from_mins(1);

/// A [`ModelClient`] that refuses to call a model which has just failed
/// repeatedly.
pub struct GuardedModelClient {
    inner: Arc<dyn ModelClient>,
    failures_to_trip: u32,
    cooldown: Duration,
    // `std::sync::Mutex`, held only for the handful of statements that read or
    // write the counter — never across an await, which is what
    // `clippy::await_holding_lock` exists to catch.
    state: Mutex<State>,
}

/// The counter, and when the breaker last gave up.
#[derive(Default)]
struct State {
    consecutive_failures: u32,
    /// `Some` while open. Cleared by the first call let through, whatever its
    /// outcome — a half-open probe that failed re-opens by tripping again.
    open_until: Option<Instant>,
}

impl GuardedModelClient {
    pub fn new(inner: Arc<dyn ModelClient>) -> Self {
        Self::with_policy(inner, FAILURES_TO_TRIP, COOLDOWN)
    }

    /// The same guard with an explicit policy, so a test can trip and recover it
    /// inside one test rather than waiting out the real cooldown.
    pub fn with_policy(
        inner: Arc<dyn ModelClient>,
        failures_to_trip: u32,
        cooldown: Duration,
    ) -> Self {
        Self {
            inner,
            failures_to_trip,
            cooldown,
            state: Mutex::new(State::default()),
        }
    }

    /// Whether this call may proceed, clearing an expired cooldown on the way
    /// past.
    fn admits(&self) -> bool {
        let Ok(mut state) = self.state.lock() else {
            // A poisoned lock means a previous holder panicked mid-update. The
            // counter is a heuristic, so failing calls closed over it would
            // trade a recoverable inaccuracy for an outage.
            return true;
        };

        match state.open_until {
            Some(until) if Instant::now() < until => false,
            Some(_) => {
                state.open_until = None;
                state.consecutive_failures = 0;
                true
            }
            None => true,
        }
    }

    /// Folds one attempt's outcome into the counter.
    fn record(&self, succeeded: bool) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };

        if succeeded {
            state.consecutive_failures = 0;
            return;
        }

        state.consecutive_failures += 1;
        if state.consecutive_failures >= self.failures_to_trip {
            state.open_until = Some(Instant::now() + self.cooldown);
        }
    }

    fn refusal() -> ModelError {
        ModelError::Unavailable("recent calls failed; waiting before trying again".to_owned())
    }
}

#[tonic::async_trait]
impl ModelClient for GuardedModelClient {
    async fn complete(&self, request: &ModelRequest) -> Result<String, ModelError> {
        if !self.admits() {
            return Err(Self::refusal());
        }

        let result = self.inner.complete(request).await;
        self.record(result.is_ok());
        result
    }

    /// Only establishing the stream counts. A failure after the first chunk has
    /// already reached the client, who has partial text on screen and a
    /// fallback would contradict rather than replace.
    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError> {
        if !self.admits() {
            return Err(Self::refusal());
        }

        let result = self.inner.stream(request).await;
        self.record(result.is_ok());
        result
    }
}
