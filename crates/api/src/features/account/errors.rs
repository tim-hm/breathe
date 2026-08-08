//! Account errors and their gRPC status mapping.

use tonic::Status;

use super::verifier::VerificationError;

/// Why a sign-in did not bind anything.
#[derive(Debug, thiserror::Error)]
pub enum AccountError {
    /// The submitted identity token is not one this server will act on —
    /// unparseable, badly signed, issued for another app, or expired. Also
    /// carries the case where Apple's keys could not be fetched, which is this
    /// server's fault rather than the caller's and is separated again on the way
    /// out.
    #[error("{0}")]
    Rejected(#[from] VerificationError),

    /// The caller's identity is already bound to a *different* Apple account.
    ///
    /// Refused rather than rebound, because rebinding would drop the first
    /// account's only route back to that history — nothing else in the schema
    /// records it. An honest client reaches this only by signing in twice
    /// without signing out in between, which is a client bug worth surfacing.
    #[error("this installation is already signed in to another Apple account")]
    AlreadyBound,

    /// The caller's row vanished between the identity layer creating it and this
    /// write. Unreachable short of a manual delete, and surfaced rather than
    /// quietly treated as a first sign-in.
    #[error("no user row for the calling user")]
    Missing,

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Logs server-side faults before converting them.
///
/// Same rule as the other features: the client receives an opaque `internal`
/// status, so a silent conversion would leave the failure unreproducible from
/// outside the process.
///
/// The split inside [`AccountError::Rejected`] is the one that matters to a
/// person. A token this server refuses is `UNAUTHENTICATED` — they did not prove
/// the account is theirs, which is a different thing from a malformed field, and
/// `EntitlementService`'s `INVALID_ARGUMENT` would be the wrong word for a
/// credential. Apple being unreachable is `UNAVAILABLE`, because telling somebody
/// their Apple ID was rejected when the truth is that we could not ask would have
/// them re-authenticating against an outage.
impl From<AccountError> for Status {
    fn from(error: AccountError) -> Self {
        match &error {
            AccountError::Rejected(VerificationError::Unavailable(e)) => {
                tracing::error!(feature = "account", error = %e, "could not reach Apple's signing keys");
                Self::unavailable("Apple's signing keys are unavailable")
            }
            AccountError::Rejected(e) => {
                // At debug: a rejected token is what a stale credential and a
                // build with the wrong bundle id both produce, and the level
                // should not imply the server is unhealthy.
                tracing::debug!(feature = "account", error = %e, "rejected an identity token");
                Self::unauthenticated(e.to_string())
            }
            AccountError::AlreadyBound => {
                tracing::warn!(
                    feature = "account",
                    "refused a sign-in on an installation bound to another Apple account"
                );
                Self::failed_precondition(error.to_string())
            }
            AccountError::Missing => {
                tracing::error!(feature = "account", "the calling user has no row");
                Self::internal("internal error")
            }
            AccountError::Database(e) => {
                tracing::error!(feature = "account", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
