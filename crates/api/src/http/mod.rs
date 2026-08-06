//! The JSON/REST surface.
//!
//! `router()` is the single aggregation point for axum routes — every path this
//! server answers over plain HTTP is visible in one place. Feature handlers
//! belong under `features::*::handlers::http` and are imported here as leaf
//! functions rather than mounted as sub-routers, so no route can exist without
//! appearing in this file.
//!
//! The domain API itself is served over gRPC-Web, not from here (see
//! docs/transport.md). These routes exist for liveness checks and for answering
//! "what is actually deployed" with `curl`.

use std::sync::Arc;

use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use serde::Serialize;

use crate::state::AppState;

/// Commit and build time, baked in by `build.rs`.
pub const BUILD_INFO: BuildInfo = BuildInfo {
    commit: env!("BUILD_GIT_COMMIT_HASH"),
    built_at: env!("BUILD_TIMESTAMP"),
};

#[derive(Debug, Clone, Copy, Serialize)]
pub struct BuildInfo {
    pub commit: &'static str,
    pub built_at: &'static str,
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/about", get(about))
        .with_state(state)
}

#[derive(Serialize)]
struct Health {
    status: &'static str,
}

/// Liveness only — deliberately does not touch the database.
///
/// A health check that fails when Postgres is unreachable turns a recoverable
/// dependency outage into a restart loop of a process that was fine.
async fn health() -> Json<Health> {
    Json(Health { status: "ok" })
}

#[derive(Serialize)]
struct About {
    #[serde(flatten)]
    build: BuildInfo,
    /// Which environment this process believes it is. Reported because
    /// `BREATHE_ENV` decides the CORS policy and the log format, and "it is
    /// running the environment I think it is" is otherwise unverifiable from
    /// outside the process.
    environment: &'static str,
}

async fn about(State(state): State<Arc<AppState>>) -> Json<About> {
    Json(About {
        build: BUILD_INFO,
        environment: state.config.environment.as_str(),
    })
}
