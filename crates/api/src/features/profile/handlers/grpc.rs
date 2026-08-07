//! `ProfileService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::profile::service;
use crate::identity;
use crate::proto::breathe::v1::profile_service_server::ProfileService;
use crate::proto::breathe::v1::{
    GetProfileRequest, GetProfileResponse, UpdateProfileRequest, UpdateProfileResponse,
};
use crate::state::AppState;

pub struct ProfileServiceImpl {
    state: Arc<AppState>,
}

impl ProfileServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

/// Every RPC here is scoped to one person, so unlike the catalogue there is
/// nothing sensible to answer a caller with no identity.
#[tonic::async_trait]
impl ProfileService for ProfileServiceImpl {
    async fn get_profile(
        &self,
        request: Request<GetProfileRequest>,
    ) -> Result<Response<GetProfileResponse>, Status> {
        let user_id = identity::require(&request)?;
        let response = service::get_profile(&self.state.pool, user_id).await?;
        Ok(Response::new(response))
    }

    async fn update_profile(
        &self,
        request: Request<UpdateProfileRequest>,
    ) -> Result<Response<UpdateProfileResponse>, Status> {
        let user_id = identity::require(&request)?;
        let response =
            service::update_profile(&self.state.pool, user_id, request.into_inner().profile)
                .await?;
        Ok(Response::new(response))
    }
}
