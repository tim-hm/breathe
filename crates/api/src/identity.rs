//! Who is calling, resolved once for every gRPC request.
//!
//! The whole of the auth model: a client generates a UUID on first launch, keeps
//! it in its Keychain, and sends it on every RPC. Possession of the id *is* the
//! claim — there is no token, no signature, and nothing here pretends otherwise.
//! That is a deliberate trade for V1 (anonymous, no account, nothing sensitive
//! stored), and the `users.apple_user_id` column is where a real credential
//! attaches when Sign in with Apple lands.
//!
//! Top-level rather than inside a feature because it sits *under* all of them:
//! the row exists before any feature is interested in it, `profile` is one
//! consumer and M5's `journey` will be another, and a layer that imported a
//! feature would invert the dependency this file's callers rely on.

use std::sync::Arc;

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;
use sqlx::PgPool;
use tonic::Status;
use uuid::Uuid;

use crate::state::AppState;

/// The header every client sends its anonymous id in.
///
/// Lowercase because gRPC metadata keys are, and a client that sends
/// `Breathe-User-Id` over HTTP/2 sends an invalid header rather than a
/// mixed-case one.
pub const USER_ID_HEADER: &str = "breathe-user-id";

/// The caller, placed in the request extensions for handlers to read.
///
/// A newtype rather than a bare `Uuid` so an extension lookup cannot silently
/// match some other id the request happens to be carrying.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UserId(pub Uuid);

/// Resolves the caller and guarantees their row exists.
///
/// Three outcomes, and the middle one is the point:
///
/// - **No header** — passes through untouched. `TechniqueService` is public
///   reference data, so requiring identity to read the catalogue would gate the
///   app's first screen on a Keychain write.
/// - **A malformed header** — `UNAUTHENTICATED`, on any service. A client that
///   sends something is claiming an identity, and a claim that does not parse is
///   a bug worth failing loudly rather than treating as anonymity.
/// - **A well-formed header** — upserts the row and injects [`UserId`].
///
/// The upsert lives here rather than in the first handler that needs a user
/// because "first sight" is literally the first RPC, whichever one that is: an
/// app that onboards offline and only ever lists techniques still has a row
/// waiting when its profile finally syncs.
pub async fn resolve(
    State(state): State<Arc<AppState>>,
    mut request: Request,
    next: Next,
) -> Response {
    let Some(header) = request.headers().get(USER_ID_HEADER) else {
        return next.run(request).await;
    };

    let Some(user_id) = header
        .to_str()
        .ok()
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        // The value itself is not logged: it is the caller's whole credential,
        // and a malformed one is still a value someone may retry successfully.
        tracing::warn!("rejected a request whose `{USER_ID_HEADER}` is not a UUID");
        return Status::unauthenticated(format!("`{USER_ID_HEADER}` must be a UUID")).into_http();
    };

    if let Err(error) = ensure_user(&state.pool, user_id).await {
        tracing::error!(%error, "failed to record the calling user");
        return Status::internal("internal error").into_http();
    }

    request.extensions_mut().insert(UserId(user_id));
    next.run(request).await
}

/// Creates the caller's row if this is the first time we have seen them.
///
/// `DO NOTHING` rather than `DO UPDATE`: every profile column has a default that
/// says "they have not answered", and an upsert that touched them would let a
/// stray RPC reset a profile back to empty.
async fn ensure_user(pool: &PgPool, user_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING",
        user_id
    )
    .execute(pool)
    .await?;

    Ok(())
}
