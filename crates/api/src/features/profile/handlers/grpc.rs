//! `ProfileService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::profile::service;
use crate::identity::{USER_ID_HEADER, UserId};
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

/// The caller, or `UNAUTHENTICATED`.
///
/// `crate::identity` has already rejected a header it could not parse, so the
/// extension being absent means no header was sent at all. Every RPC on this
/// service is scoped to one person, so unlike the catalogue there is nothing
/// sensible to answer with.
fn caller<T>(request: &Request<T>) -> Result<UserId, Status> {
    request
        .extensions()
        .get::<UserId>()
        .copied()
        .ok_or_else(|| Status::unauthenticated(format!("`{USER_ID_HEADER}` is required")))
}

#[tonic::async_trait]
impl ProfileService for ProfileServiceImpl {
    async fn get_profile(
        &self,
        request: Request<GetProfileRequest>,
    ) -> Result<Response<GetProfileResponse>, Status> {
        let UserId(user_id) = caller(&request)?;
        let response = service::get_profile(&self.state.pool, user_id).await?;
        Ok(Response::new(response))
    }

    async fn update_profile(
        &self,
        request: Request<UpdateProfileRequest>,
    ) -> Result<Response<UpdateProfileResponse>, Status> {
        let UserId(user_id) = caller(&request)?;
        let response =
            service::update_profile(&self.state.pool, user_id, request.into_inner().profile)
                .await?;
        Ok(Response::new(response))
    }
}
