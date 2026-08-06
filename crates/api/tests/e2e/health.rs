//! The JSON surface.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use tower::ServiceExt;

use crate::harness::build_app;

/// `/health` is documented as liveness-only, and the reason is operational: a
/// health check that fails when Postgres is unreachable turns a recoverable
/// dependency outage into a restart loop of a process that was fine.
///
/// The pool here is lazy and points at a port nothing listens on, so the route
/// answering at all proves it issued no query. Adding one to `/health` later
/// fails here rather than in an incident.
#[tokio::test]
async fn health_answers_without_a_reachable_database() {
    let options: PgConnectOptions = "postgres://nobody@127.0.0.1:1/nowhere"
        .parse()
        .expect("a valid connection string");
    let unreachable = PgPoolOptions::new().connect_lazy_with(options);

    let response = build_app(unreachable.clone())
        .oneshot(
            Request::get("/health")
                .body(Body::empty())
                .expect("a valid request"),
        )
        .await
        .expect("the router is infallible");

    assert_eq!(response.status(), StatusCode::OK);

    // A lazy pool keeps a connector task alive; without this nextest reports the
    // test as leaky because the process still holds it at exit.
    unreachable.close().await;
}
