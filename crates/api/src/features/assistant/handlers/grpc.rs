//! `AssistantService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::assistant::service::{self, ExplanationStream};
use crate::identity;
use crate::proto::breathe::v1::assistant_service_server::AssistantService;
use crate::proto::breathe::v1::{
    ChatRequest, ExplainTechniqueRequest, GetRecommendationRequest, GetRecommendationResponse,
};
use crate::state::AppState;

/// The `AssistantService` transport, holding the shared state its RPCs read the
/// pool and the model seam out of.
///
/// The model client lives on `AppState` rather than being built per request:
/// which provider is installed is a boot-time decision, and the breaker in front
/// of it only works if every caller shares one.
pub struct AssistantServiceImpl {
    state: Arc<AppState>,
}

impl AssistantServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

/// Both RPCs are scoped to one person: the guidance is shaped by their profile,
/// and there is nothing to say to a caller without one.
#[tonic::async_trait]
impl AssistantService for AssistantServiceImpl {
    async fn get_recommendation(
        &self,
        request: Request<GetRecommendationRequest>,
    ) -> Result<Response<GetRecommendationResponse>, Status> {
        let user_id = identity::require(&request)?;
        // The health context is special-category data passing through: handed
        // straight to the service, never logged, never stored — the request
        // must not be formatted anywhere on this path.
        let health = request.into_inner().health_context;
        let response = service::get_recommendation(
            &self.state.pool,
            self.state.assistant.as_ref(),
            user_id,
            health,
        )
        .await?;
        Ok(Response::new(response))
    }

    /// The repo's first server-streaming RPC. tonic wants the stream type named
    /// on the trait, which is why `service` returns an already-boxed one rather
    /// than something concrete this file would have to spell out twice.
    type ExplainTechniqueStream = ExplanationStream;

    async fn explain_technique(
        &self,
        request: Request<ExplainTechniqueRequest>,
    ) -> Result<Response<Self::ExplainTechniqueStream>, Status> {
        let user_id = identity::require(&request)?;
        let request = request.into_inner();

        let stream = service::explain_technique(
            &self.state.pool,
            self.state.assistant.as_ref(),
            user_id,
            &request.technique_slug,
            request.health_context,
        )
        .await?;

        Ok(Response::new(stream))
    }

    // Qualified rather than imported: an imported `ChatStream` would collide
    // with the associated type's own name in this scope.
    type ChatStream = service::ChatStream;

    async fn chat(
        &self,
        request: Request<ChatRequest>,
    ) -> Result<Response<Self::ChatStream>, Status> {
        let user_id = identity::require(&request)?;
        // The transcript is the person's own conversation and the health
        // context is special-category data: both pass straight through,
        // never logged, never stored — same rule as the RPCs above.
        let request = request.into_inner();

        let stream = service::chat(
            &self.state.pool,
            self.state.assistant.as_ref(),
            user_id,
            request.history,
            &request.message,
            request.health_context,
        )
        .await?;

        Ok(Response::new(stream))
    }
}
