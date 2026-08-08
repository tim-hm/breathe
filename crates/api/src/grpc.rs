//! gRPC service registration — the single place a service becomes reachable.

use std::sync::Arc;

use anyhow::{Context, Result};
use tonic::service::Routes;

use crate::features::account::handlers::grpc::AccountServiceImpl;
use crate::features::assistant::handlers::grpc::AssistantServiceImpl;
use crate::features::entitlement::handlers::grpc::EntitlementServiceImpl;
use crate::features::journey::handlers::grpc::JourneyServiceImpl;
use crate::features::profile::handlers::grpc::ProfileServiceImpl;
use crate::features::technique::handlers::grpc::TechniqueServiceImpl;
use crate::features::user_technique::handlers::grpc::UserTechniqueServiceImpl;
use crate::proto::ond::v1::FILE_DESCRIPTOR_SET;
use crate::proto::ond::v1::account_service_server::AccountServiceServer;
use crate::proto::ond::v1::assistant_service_server::AssistantServiceServer;
use crate::proto::ond::v1::entitlement_service_server::EntitlementServiceServer;
use crate::proto::ond::v1::journey_service_server::JourneyServiceServer;
use crate::proto::ond::v1::profile_service_server::ProfileServiceServer;
use crate::proto::ond::v1::technique_service_server::TechniqueServiceServer;
use crate::proto::ond::v1::user_technique_service_server::UserTechniqueServiceServer;
use crate::state::AppState;

/// The largest request body any service will decode.
///
/// tonic reserves whatever a frame's length prefix declares, once it has
/// checked that number against this limit — so the ceiling is what a hostile
/// client can make this process allocate per request, and the default leaves it
/// at 4 MiB. The service-level bounds (`journey`'s 200 sessions per batch, the
/// 8 KiB ceiling on a submitted App Store token) cannot help: they run against
/// a message that has already been read.
///
/// 256 KiB sits roughly six times above the biggest legitimate request, a full
/// 200-session `RecordSessions` batch, which leaves the contract room to grow
/// fields without anybody having to remember this number exists.
const MAX_REQUEST_BYTES: usize = 256 * 1024;

/// Reflection is registered on local environments only, so `grpcurl` can call a
/// development server without a local copy of the .proto files. Serving it in
/// production would publish every RPC, field and enum — including the
/// entitlement surface — to anyone who asks. Wanting it against the deployed box
/// is the argument for the separate port `docs/observability.md` reserves for
/// metrics, not for registering it here. `infra/box/Caddyfile` declines to proxy
/// the path as well, because an unset `OND_ENV` falls back to `Dev` and this
/// gate therefore fails open.
///
/// There is deliberately no `tonic-health` service. Liveness is answered by the
/// JSON `/health` route, which is what an orchestrator or a human with `curl`
/// will actually probe; a second health surface that nothing queries is a
/// dependency and a status reporter to keep correct for no reader.
pub fn build_services(state: &Arc<AppState>) -> Result<Routes> {
    let mut routes = Routes::default()
        .add_service(
            TechniqueServiceServer::new(TechniqueServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            UserTechniqueServiceServer::new(UserTechniqueServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            ProfileServiceServer::new(ProfileServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            JourneyServiceServer::new(JourneyServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            AssistantServiceServer::new(AssistantServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            EntitlementServiceServer::new(EntitlementServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        )
        .add_service(
            AccountServiceServer::new(AccountServiceImpl::new(Arc::clone(state)))
                .max_decoding_message_size(MAX_REQUEST_BYTES),
        );

    if state.config.is_local() {
        let reflection = tonic_reflection::server::Builder::configure()
            .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET)
            .build_v1()
            .context("failed to build the gRPC reflection service")?;
        routes = routes.add_service(reflection);
    }

    Ok(routes)
}

#[cfg(test)]
mod tests {
    use axum::body::Body;
    use axum::http::Request;
    use sqlx::PgPool;
    use tonic::Code;
    use tower::ServiceExt;

    use super::*;
    use crate::account::AppleIdentityVerifier;
    use crate::assistant::DisabledModelClient;
    use crate::config::{Config, Environment};
    use crate::entitlement::AppStoreVerifier;

    /// The reflection service's path, as `tonic-reflection` registers it. A
    /// literal rather than a constant read back from the crate: the point of
    /// the test is that this exact path is unreachable in production, and a
    /// name derived from the same source as the registration could not fail.
    const REFLECTION_PATH: &str = "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo";

    const DATABASE_URL: &str = "postgres://postgres@localhost:18101/ond";

    /// A state with no database behind it. `connect_lazy` parses the URL and
    /// connects on first use, and registration touches neither — nor does it
    /// touch the model or either verifier, which are here only because
    /// `AppState` has the fields.
    fn state_for(environment: Environment) -> Arc<AppState> {
        AppState::new(
            PgPool::connect_lazy(DATABASE_URL).unwrap(),
            Config {
                environment,
                database_url: DATABASE_URL.to_owned(),
                port: 18100,
            },
            Arc::new(DisabledModelClient),
            Arc::new(AppStoreVerifier),
            Arc::new(AppleIdentityVerifier::new().unwrap()),
        )
    }

    /// Whether the router answers a path with tonic's "no such service"
    /// fallback, which is what an unregistered service looks like from outside.
    async fn is_unimplemented(environment: Environment) -> bool {
        let router = build_services(&state_for(environment))
            .unwrap()
            .prepare()
            .into_axum_router();

        let response = router
            .oneshot(Request::post(REFLECTION_PATH).body(Body::empty()).unwrap())
            .await
            .unwrap();

        response
            .headers()
            .get("grpc-status")
            .is_some_and(|status| Code::from_bytes(status.as_bytes()) == Code::Unimplemented)
    }

    /// Serving reflection from a deployment would publish every RPC, field and
    /// enum — the entitlement surface included — to anyone who asks. The gate
    /// is one `if`, and this is what stops the next person deleting it.
    #[tokio::test]
    async fn reflection_is_absent_from_a_deployment() {
        assert!(is_unimplemented(Environment::Production).await);
        assert!(
            !is_unimplemented(Environment::Dev).await,
            "a developer's `grpcurl` still needs it"
        );
    }
}
