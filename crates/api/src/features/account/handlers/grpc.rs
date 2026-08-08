//! `AccountService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::account::service;
use crate::identity;
use crate::proto::ond::v1::account_service_server::AccountService;
use crate::proto::ond::v1::{
    DeleteAccountRequest, DeleteAccountResponse, SignInWithAppleRequest, SignInWithAppleResponse,
};
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

    /// Requires an identity for the reason the sign-in does, turned around: with
    /// no header there is nothing to erase, and a call that answered `OK` to one
    /// would tell somebody their account is gone having touched nothing.
    async fn delete_account(
        &self,
        request: Request<DeleteAccountRequest>,
    ) -> Result<Response<DeleteAccountResponse>, Status> {
        let user_id = identity::require(&request)?;

        let response = service::delete_account(&self.state.pool, user_id).await?;

        Ok(Response::new(response))
    }
}
