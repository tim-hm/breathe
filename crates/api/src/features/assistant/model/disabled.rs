//! The client installed when no provider key is configured.

use super::{ModelClient, ModelError, ModelRequest, ModelStream};

/// Refuses every call, with the same `Unavailable` the breaker gives.
///
/// Which is the point: "no key" is not a mode the service knows about. It takes
/// the path a tripped breaker takes, so a fresh clone and a CI run exercise the
/// fallback that a real outage would, rather than a branch nothing else reaches.
pub struct DisabledModelClient;

#[tonic::async_trait]
impl ModelClient for DisabledModelClient {
    async fn complete(&self, _request: &ModelRequest) -> Result<String, ModelError> {
        Err(ModelError::unavailable("no model is configured"))
    }

    async fn stream(&self, _request: &ModelRequest) -> Result<ModelStream, ModelError> {
        Err(ModelError::unavailable("no model is configured"))
    }

    /// Never. Nothing here can change, so the caller can skip the quota claim
    /// and the prompt outright rather than preparing a call that is certain to
    /// be refused.
    fn is_available(&self) -> bool {
        false
    }
}
