//! The breathe API.
//!
//! Serves gRPC-Web (the domain API, consumed by the iOS client) and a small JSON
//! surface (`/health`, `/about`) on a single port. Boot order is: configuration,
//! telemetry, database pool, routers, serve.

mod config;
mod features;
mod grpc;
mod http;
mod obs;
mod proto;
mod state;

use anyhow::{Context, Result};
use sqlx::postgres::PgPoolOptions;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

use crate::state::AppState;

/// Sized for a local machine and a small deployment. Postgres' own default
/// `max_connections` is 100, so this leaves ample room for the migrate binary
/// and a psql session alongside.
const MAX_DB_CONNECTIONS: u32 = 10;

#[tokio::main]
async fn main() -> Result<()> {
    let config = config::load()?;
    obs::init(config.wants_json_logs());

    tracing::info!(
        commit = http::BUILD_INFO.commit,
        built_at = http::BUILD_INFO.built_at,
        environment = ?config.environment,
        "starting breathe api",
    );

    let pool = PgPoolOptions::new()
        .max_connections(MAX_DB_CONNECTIONS)
        // Keeps one connection warm. Without it, the first request after an idle
        // period pays full TCP, TLS, and Postgres auth — which on a low-traffic
        // service is most requests.
        .min_connections(1)
        .connect(&config.database_url)
        .await
        .context("failed to connect to the database — is `mise run dev:db` running?")?;
    tracing::info!("connected to the database");

    let port = config.port;
    let cors = cors_layer(config.is_local());
    let state = AppState::new(pool, config);

    // gRPC paths are `/breathe.v1.<Service>/<Method>` and can never collide with
    // the JSON routes (`/health`, `/about`), so HTTP matches first and anything
    // unmatched falls through to gRPC.
    let grpc_router = grpc::build_services(&state)?
        .prepare()
        .into_axum_router()
        .layer(tonic_web::GrpcWebLayer::new());

    let app = http::router(state)
        .fallback_service(grpc_router)
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .with_context(|| format!("failed to bind port {port}"))?;
    tracing::info!(port, "listening");

    axum::serve(listener, app)
        .await
        .context("server terminated unexpectedly")?;

    Ok(())
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
