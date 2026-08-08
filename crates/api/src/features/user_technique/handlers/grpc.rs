//! `UserTechniqueService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::user_technique::service;
use crate::identity;
use crate::proto::ond::v1::user_technique_service_server::UserTechniqueService;
use crate::proto::ond::v1::{
    CreateUserTechniqueRequest, CreateUserTechniqueResponse, DeleteUserTechniqueRequest,
    DeleteUserTechniqueResponse, ListUserTechniquesRequest, ListUserTechniquesResponse,
    UpdateUserTechniqueRequest, UpdateUserTechniqueResponse,
};
use crate::state::AppState;

pub struct UserTechniqueServiceImpl {
    state: Arc<AppState>,
}

impl UserTechniqueServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

/// Every RPC here requires identity. Unlike the catalogue, there is no anonymous
/// reading of somebody's own techniques — a caller with no id has none.
#[tonic::async_trait]
impl UserTechniqueService for UserTechniqueServiceImpl {
    async fn list_user_techniques(
        &self,
        request: Request<ListUserTechniquesRequest>,
    ) -> Result<Response<ListUserTechniquesResponse>, Status> {
        let user_id = identity::require(&request)?;
        let response = service::list(&self.state.pool, user_id).await?;
        Ok(Response::new(response))
    }

    async fn create_user_technique(
        &self,
        request: Request<CreateUserTechniqueRequest>,
    ) -> Result<Response<CreateUserTechniqueResponse>, Status> {
        let user_id = identity::require(&request)?;
        let response =
            service::create(&self.state.pool, user_id, request.into_inner().draft).await?;
        Ok(Response::new(response))
    }

    async fn update_user_technique(
        &self,
        request: Request<UpdateUserTechniqueRequest>,
    ) -> Result<Response<UpdateUserTechniqueResponse>, Status> {
        let user_id = identity::require(&request)?;
        let request = request.into_inner();
        let response =
            service::update(&self.state.pool, user_id, &request.id, request.draft).await?;
        Ok(Response::new(response))
    }

    async fn delete_user_technique(
        &self,
        request: Request<DeleteUserTechniqueRequest>,
    ) -> Result<Response<DeleteUserTechniqueResponse>, Status> {
        let user_id = identity::require(&request)?;
        let response = service::delete(&self.state.pool, user_id, &request.into_inner().id).await?;
        Ok(Response::new(response))
    }
}
