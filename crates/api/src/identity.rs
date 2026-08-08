//! Who is calling, resolved once for every gRPC request.
//!
//! The whole of the auth model on the request path: a client generates a UUID on
//! first launch, keeps it in its Keychain, and sends it on every RPC. Possession
//! of the id *is* the claim — there is no token, no signature, and nothing here
//! pretends otherwise. That is a deliberate trade (anonymous, no account,
//! nothing sensitive stored), and it holds for as long as the device does.
//!
//! The credential that survives a change of device attaches through
//! `features::account`, which writes `users.apple_user_id`. Signing in can
//! therefore *change* which id a client sends: an Apple account that already has
//! a row means the caller's anonymous identity is folded into it and then
//! deleted, so a row this file created can stop existing between one request and
//! the next. What moves, what is summed, and what is left behind is documented
//! in full on `features::account::repository::merge`.
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
use crate::{obs, throttle};

/// The header every client sends its anonymous id in.
///
/// Lowercase because gRPC metadata keys are, and a client that sends
/// `Ond-User-Id` over HTTP/2 sends an invalid header rather than a
/// mixed-case one.
pub const USER_ID_HEADER: &str = "ond-user-id";

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
///
/// A well-formed header is a claim anybody can make, though, and a fresh one
/// each time is a `users` row each time. So creating a row is charged against
/// `throttle::Throttle::spend_new_identity`, and a caller over that budget is
/// refused *instead of* being written. Merely being an identity stays free: an
/// established client's row already exists, so the branch that spends never
/// runs for them.
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

    // Before the database work, not after: everything this request logs from
    // here on — the failures below, each feature's `From<…> for Status`, and the
    // layer's own completion line — is only attributable to a person once the
    // span carries them.
    obs::record_user_id(user_id);

    match known_user(&state.pool, user_id).await {
        Err(error) => {
            tracing::error!(%error, "failed to look up the calling user");
            return Status::internal("internal error").into_http();
        }
        Ok(true) => {}
        Ok(false) => {
            if !state
                .throttle
                .spend_new_identity(throttle::client_key(request.headers()))
            {
                tracing::warn!("refused a request creating an identity over its rate limit");
                return throttle::refused();
            }

            if let Err(error) = create_user(&state.pool, user_id).await {
                tracing::error!(%error, "failed to record the calling user");
                return Status::internal("internal error").into_http();
            }
        }
    }

    request.extensions_mut().insert(UserId(user_id));
    next.run(request).await
}

/// The caller, for a service that has nothing to answer without one.
///
/// [`resolve`] has already rejected a header it could not parse, so a missing
/// extension means no header was sent at all. Living beside the newtype rather
/// than in the one feature that currently calls it: M5's `journey` is the next
/// service scoped to a person, and two features deciding this separately is two
/// chances to disagree on the status or the wording.
pub fn require<T>(request: &tonic::Request<T>) -> Result<UserId, Status> {
    request
        .extensions()
        .get::<UserId>()
        .copied()
        .ok_or_else(|| Status::unauthenticated(format!("`{USER_ID_HEADER}` is required")))
}

/// Whether we have seen this caller before.
///
/// Split out from the insert, and asked first, because the budget that rations
/// new identities has to be consulted *before* anything is written — a check
/// after the fact caps nothing, since the row it would have refused already
/// exists. This is what turns the write on the path of every identified request
/// into a primary-key lookup on the path of every *returning* one, which is the
/// overwhelming majority.
///
/// A concurrent pair of first sights can both read `false` and both spend from
/// the budget. That costs one unit of allowance, not a second row: the insert
/// below still declines the conflict.
async fn known_user(pool: &PgPool, user_id: Uuid) -> Result<bool, sqlx::Error> {
    let row = sqlx::query_scalar!("SELECT 1 FROM users WHERE id = $1", user_id)
        .fetch_optional(pool)
        .await?;

    Ok(row.is_some())
}

/// Records a caller we have not seen before.
///
/// `DO NOTHING` rather than `DO UPDATE`: every profile column has a default that
/// says "they have not answered", and an upsert that touched them would let a
/// stray RPC reset a profile back to empty. It also absorbs the race
/// [`known_user`] describes.
///
/// The write stays here rather than moving into the one handler that needs a
/// row, because "first sight" is the first RPC whichever one that is: an app
/// that onboards offline and only ever lists techniques still has a row waiting
/// when its profile finally syncs. What changed is not where it happens but who
/// is allowed to cause it.
async fn create_user(pool: &PgPool, user_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING",
        user_id
    )
    .execute(pool)
    .await?;

    Ok(())
}
