//! Process entry point for the önd API.
//!
//! Boot order is: configuration, telemetry, database pool, router, serve. The
//! router itself is `api::build_app` so that the integration tests exercise the
//! same stack this binary serves.

use std::sync::Arc;

use anyhow::{Context, Result};
use api::entitlement::AppStoreVerifier;
use api::state::AppState;
use api::{assistant, config, http, obs};
use sqlx::postgres::PgPoolOptions;

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
        "starting ond api",
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

    // The composition root's one real choice: which side of the assistant's
    // model seam this process runs. Logged there, either way.
    let assistant = assistant::from_config(&config);

    // No equivalent choice for the App Store: the trust anchor is compiled in,
    // so every environment runs the same verifier and there is no configuration
    // that could relax it.
    let state = AppState::new(pool, config, assistant, Arc::new(AppStoreVerifier));
    let port = state.config.port;
    let app = api::build_app(state)?;

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .with_context(|| format!("failed to bind port {port}"))?;
    tracing::info!(port, "listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("server terminated unexpectedly")?;

    Ok(())
}

/// Resolves when the process is asked to stop: SIGINT (^C in a terminal) or
/// SIGTERM (what container runtimes and supervisors send first). Handing this
/// to `with_graceful_shutdown` lets in-flight requests drain instead of being
/// severed mid-response.
///
/// A handler that fails to install logs and parks forever rather than
/// panicking — the other signal (or SIGKILL) still ends the process.
async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            tracing::error!(%error, "failed to install the SIGINT handler");
            std::future::pending::<()>().await;
        }
    };

    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(error) => {
                tracing::error!(%error, "failed to install the SIGTERM handler");
                std::future::pending::<()>().await;
            }
        }
    };

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }

    tracing::info!("shutdown signal received, draining in-flight requests");
}
