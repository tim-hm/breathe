//! `TechniqueService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::technique::service;
use crate::proto::breathe::v1::technique_service_server::TechniqueService;
use crate::proto::breathe::v1::{ListTechniquesRequest, ListTechniquesResponse};
use crate::state::AppState;

pub struct TechniqueServiceImpl {
    state: Arc<AppState>,
}

impl TechniqueServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

#[tonic::async_trait]
impl TechniqueService for TechniqueServiceImpl {
    async fn list_techniques(
        &self,
        _request: Request<ListTechniquesRequest>,
    ) -> Result<Response<ListTechniquesResponse>, Status> {
        let response = service::list_techniques(&self.state.pool).await?;
        Ok(Response::new(response))
    }
}
