//! gRPC service registration — the single place a service becomes reachable.

use std::sync::Arc;

use anyhow::{Context, Result};
use tonic::service::Routes;

use crate::features::assistant::handlers::grpc::AssistantServiceImpl;
use crate::features::entitlement::handlers::grpc::EntitlementServiceImpl;
use crate::features::journey::handlers::grpc::JourneyServiceImpl;
use crate::features::profile::handlers::grpc::ProfileServiceImpl;
use crate::features::technique::handlers::grpc::TechniqueServiceImpl;
use crate::proto::breathe::v1::FILE_DESCRIPTOR_SET;
use crate::proto::breathe::v1::assistant_service_server::AssistantServiceServer;
use crate::proto::breathe::v1::entitlement_service_server::EntitlementServiceServer;
use crate::proto::breathe::v1::journey_service_server::JourneyServiceServer;
use crate::proto::breathe::v1::profile_service_server::ProfileServiceServer;
use crate::proto::breathe::v1::technique_service_server::TechniqueServiceServer;
use crate::state::AppState;

/// Reflection is registered on local environments only, so `grpcurl` can call a
/// development server without a local copy of the .proto files. Serving it in
/// production would publish every RPC, field and enum — including the
/// entitlement surface — to anyone who asks. Wanting it against the deployed box
/// is the argument for the separate port `docs/observability.md` reserves for
/// metrics, not for registering it here. `infra/box/Caddyfile` declines to proxy
/// the path as well, because an unset `BREATHE_ENV` falls back to `Dev` and this
/// gate therefore fails open.
///
/// There is deliberately no `tonic-health` service. Liveness is answered by the
/// JSON `/health` route, which is what an orchestrator or a human with `curl`
/// will actually probe; a second health surface that nothing queries is a
/// dependency and a status reporter to keep correct for no reader.
pub fn build_services(state: &Arc<AppState>) -> Result<Routes> {
    let mut routes = Routes::default()
        .add_service(TechniqueServiceServer::new(TechniqueServiceImpl::new(
            Arc::clone(state),
        )))
        .add_service(ProfileServiceServer::new(ProfileServiceImpl::new(
            Arc::clone(state),
        )))
        .add_service(JourneyServiceServer::new(JourneyServiceImpl::new(
            Arc::clone(state),
        )))
        .add_service(AssistantServiceServer::new(AssistantServiceImpl::new(
            Arc::clone(state),
        )))
        .add_service(EntitlementServiceServer::new(EntitlementServiceImpl::new(
            Arc::clone(state),
        )));

    if state.config.is_local() {
        let reflection = tonic_reflection::server::Builder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET)
            .build_v1()
            .context("failed to build the gRPC reflection service")?;
        routes = routes.add_service(reflection);
    }

    Ok(routes)
}
