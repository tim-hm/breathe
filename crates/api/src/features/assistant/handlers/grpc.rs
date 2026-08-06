//! `AssistantService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::assistant::service::{self, ExplanationStream};
use crate::identity::{self, UserId};
use crate::proto::breathe::v1::assistant_service_server::AssistantService;
use crate::proto::breathe::v1::{
    ExplainTechniqueRequest, GetRecommendationRequest, GetRecommendationResponse,
};
use crate::state::AppState;

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
        let UserId(user_id) = identity::require(&request)?;
        let response =
            service::get_recommendation(&self.state.pool, self.state.assistant.as_ref(), user_id)
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
        let UserId(user_id) = identity::require(&request)?;
        let slug = request.into_inner().technique_slug;

        let stream = service::explain_technique(
            &self.state.pool,
            self.state.assistant.as_ref(),
            user_id,
            &slug,
        )
        .await?;

        Ok(Response::new(stream))
    }
}
