//! Business logic — turns a proven Apple account into the identity the device
//! should carry from now on, and erases one on request.
//!
//! Receives explicit dependencies (`&PgPool`, `&dyn IdentityTokenVerifier`),
//! never `Arc<AppState>`, and contains zero raw queries.

use sqlx::PgPool;

use super::errors::AccountError;
use super::repository;
use super::verifier::IdentityTokenVerifier;
use crate::identity::UserId;
use crate::proto::ond::v1 as pb;

/// Verifies the identity token and binds the Apple account it names.
///
/// The response's id is the whole point of the call: it is the caller's own on a
/// first sign-in and an older identity when this Apple account already had one,
/// and the client persists it either way. What decides which — and what happens
/// to the caller's history in the second case — is
/// `repository::bind_apple_account`.
pub async fn sign_in_with_apple(
    pool: &PgPool,
    verifier: &dyn IdentityTokenVerifier,
    caller: UserId,
    identity_token: &str,
) -> Result<pb::SignInWithAppleResponse, AccountError> {
    let identity = verifier.verify(identity_token).await?;
    let adopted = repository::bind_apple_account(pool, caller, &identity.apple_user_id).await?;

    if adopted != caller.0 {
        // One identity ceasing to exist and another absorbing its history is the
        // only destructive thing this server does on a client's say-so, and this
        // line is the only account of it. The Apple id is deliberately absent:
        // it is the credential the whole binding rests on, and neither id here
        // is useful without it.
        tracing::info!(
            feature = "account",
            from = %caller.0,
            to = %adopted,
            "merged an anonymous identity into a signed-in one"
        );
    }

    Ok(pb::SignInWithAppleResponse {
        user_id: adopted.to_string(),
    })
}

/// Erases the caller and everything filed under them.
///
/// Logged at `info` for the same reason the merge above is: this is the second
/// of the two destructive things the server does on a client's say-so, and the
/// row it names will not exist afterwards to be asked about. The id is not
/// repeated here — `identity::resolve` has already put it on the span, and what
/// was erased is by definition not something to write down on the way past.
pub async fn delete_account(
    pool: &PgPool,
    caller: UserId,
) -> Result<pb::DeleteAccountResponse, AccountError> {
    repository::delete_account(pool, caller).await?;

    tracing::info!(
        feature = "account",
        "erased an account at its owner's request"
    );

    Ok(pb::DeleteAccountResponse {})
}
