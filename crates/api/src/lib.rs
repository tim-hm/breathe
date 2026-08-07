//! The breathe API.
//!
//! Serves gRPC-Web (the domain API, consumed by the iOS client) and a small JSON
//! surface (`/health`, `/about`) from one router on one port.
//!
//! Everything except process startup lives here rather than in `main.rs` so that
//! `tests/e2e` can drive the exact router the binary serves. A harness that
//! assembled its own router would verify a stack no deployment runs.

mod features;
mod grpc;

/// The assistant's model seam — one of the two dependencies this crate takes
/// that its caller has to choose, and therefore one of the few things a feature
/// exposes outside the crate.
///
/// A named re-export rather than making `features` public: the composition root
/// and `tests/e2e` need to name a handful of types, and publishing the whole
/// feature tree to get them would also publish every service, repository, and
/// error type — which is exactly the backdoor docs/code-structure.md's "nothing
/// bypasses a feature's public surface" rules out. Adding to this list is a
/// visible decision.
pub mod assistant {
    pub use crate::features::assistant::model::breaker::GuardedModelClient;
    pub use crate::features::assistant::model::disabled::DisabledModelClient;
    pub use crate::features::assistant::model::openrouter::OpenRouterClient;
    pub use crate::features::assistant::model::{
        ModelClient, ModelError, ModelRequest, ModelStream, from_config,
    };
    pub use crate::features::assistant::types::daily_model_calls;
}

/// The App Store signature seam, published on the same terms as `assistant`.
///
/// `Tier` travels with it because the allowance is a function of one, so a test
/// asking how many calls a subscriber gets has to be able to name it.
pub mod entitlement {
    pub use crate::features::entitlement::types::Tier;
    pub use crate::features::entitlement::verifier::{
        AppStoreVerifier, TransactionVerifier, VerificationError, VerifiedTransaction,
    };
}

pub mod config;
pub mod http;
pub mod identity;
pub mod obs;
pub mod proto;
pub mod state;

use std::sync::Arc;

use anyhow::Result;
use axum::Router;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

use crate::state::AppState;

/// Assembles the one router that answers both protocols.
///
/// gRPC paths are `/breathe.v1.<Service>/<Method>` and can never collide with
/// the JSON routes (`/health`, `/about`), so HTTP matches first and anything
/// unmatched falls through to gRPC.
pub fn build_app(state: Arc<AppState>) -> Result<Router> {
    let cors = cors_layer(state.config.is_local());

    let grpc_router = grpc::build_services(&state)?
        .prepare()
        .into_axum_router()
        // Inside `GrpcWebLayer`, so it sees a plain gRPC request and its error
        // responses are re-framed as gRPC-Web on the way out. Only the gRPC
        // router carries it: `/health` must answer without a database, and an
        // identity that upserts a row is exactly the dependency that would
        // break.
        .layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            identity::resolve,
        ))
        .layer(tonic_web::GrpcWebLayer::new());

    Ok(http::router(state)
        .fallback_service(grpc_router)
        .layer(cors)
        .layer(TraceLayer::new_for_http()))
}

/// gRPC-Web carries its status out-of-band in the `grpc-status` and
/// `grpc-message` headers, so a client cannot read a response — even a
/// successful one — unless those headers are explicitly exposed. Omitting them
/// produces a request that succeeds on the wire and fails in the client.
fn cors_layer(is_local: bool) -> CorsLayer {
    let layer = CorsLayer::new()
        .allow_methods(Any)
        .allow_headers(Any)
        .expose_headers([
            axum::http::HeaderName::from_static("grpc-status"),
            axum::http::HeaderName::from_static("grpc-message"),
        ]);

    if is_local {
        layer.allow_origin(Any)
    } else {
        // Deployed origins are not known yet. Refusing every cross-origin
        // request is the correct placeholder: the iOS client is not a browser
        // and sends no Origin, so this restricts nothing it needs.
        layer
    }
}

#[cfg(test)]
mod tests {
    use axum::body::Body;
    use axum::http::{Request, header};
    use axum::routing::get;
    use tower::ServiceExt;

    use super::*;

    /// Exposing `grpc-status`/`grpc-message` is the whole reason `cors_layer`
    /// exists (docs/transport.md): without them a gRPC-Web response succeeds on
    /// the wire and fails in the client, silently.
    #[tokio::test]
    async fn exposes_the_grpc_status_headers() {
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(cors_layer(true));

        let response = app
            .oneshot(
                Request::get("/")
                    .header(header::ORIGIN, "http://localhost:18100")
                    .body(Body::empty())
                    .expect("a valid request"),
            )
            .await
            .expect("the router is infallible");

        let exposed = response
            .headers()
            .get(header::ACCESS_CONTROL_EXPOSE_HEADERS)
            .expect("the expose-headers header is present")
            .to_str()
            .expect("header value is ASCII");
        assert!(exposed.contains("grpc-status"));
        assert!(exposed.contains("grpc-message"));
    }
}
