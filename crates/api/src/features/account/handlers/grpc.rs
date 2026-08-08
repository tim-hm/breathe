//! `AccountService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::account::service;
use crate::identity;
use crate::proto::ond::v1::account_service_server::AccountService;
use crate::proto::ond::v1::{SignInWithAppleRequest, SignInWithAppleResponse};
use crate::state::AppState;

pub struct AccountServiceImpl {
    state: Arc<AppState>,
}

impl AccountServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

/// Scoped to one person exactly as every other service is: the anonymous
/// identity travels in the `ond-user-id` header, and there is nothing to answer a
/// caller without one — a sign-in with no identity to bind would have to mint a
/// row the client never asked for.
#[tonic::async_trait]
impl AccountService for AccountServiceImpl {
    async fn sign_in_with_apple(
        &self,
        request: Request<SignInWithAppleRequest>,
    ) -> Result<Response<SignInWithAppleResponse>, Status> {
        let user_id = identity::require(&request)?;
        let identity_token = request.into_inner().identity_token;

        let response = service::sign_in_with_apple(
            &self.state.pool,
            self.state.account.as_ref(),
            user_id,
            &identity_token,
        )
        .await?;

        Ok(Response::new(response))
    }
}
