//! `EntitlementService` gRPC implementation.

use std::sync::Arc;

use tonic::{Request, Response, Status};

use crate::features::entitlement::service;
use crate::identity::{self, UserId};
use crate::proto::breathe::v1::entitlement_service_server::EntitlementService;
use crate::proto::breathe::v1::{
    GetEntitlementRequest, GetEntitlementResponse, SubmitAppStoreTransactionRequest,
    SubmitAppStoreTransactionResponse,
};
use crate::state::AppState;

pub struct EntitlementServiceImpl {
    state: Arc<AppState>,
}

impl EntitlementServiceImpl {
    pub const fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }
}

/// Both RPCs are scoped to one person: an entitlement belongs to whoever the
/// header names, and there is nothing to answer a caller without one.
#[tonic::async_trait]
impl EntitlementService for EntitlementServiceImpl {
    async fn submit_app_store_transaction(
        &self,
        request: Request<SubmitAppStoreTransactionRequest>,
    ) -> Result<Response<SubmitAppStoreTransactionResponse>, Status> {
        let UserId(user_id) = identity::require(&request)?;
        let signed_transaction = request.into_inner().signed_transaction;

        let response = service::submit_transaction(
            &self.state.pool,
            self.state.entitlement.as_ref(),
            user_id,
            &signed_transaction,
        )
        .await?;

        Ok(Response::new(response))
    }

    async fn get_entitlement(
        &self,
        request: Request<GetEntitlementRequest>,
    ) -> Result<Response<GetEntitlementResponse>, Status> {
        let UserId(user_id) = identity::require(&request)?;
        let response = service::get_entitlement(&self.state.pool, user_id).await?;
        Ok(Response::new(response))
    }
}
