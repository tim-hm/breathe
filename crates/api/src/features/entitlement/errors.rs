//! Entitlement errors and their gRPC status mapping.

use tonic::Status;

use super::verifier::VerificationError;

#[derive(Debug, thiserror::Error)]
pub enum EntitlementError {
    /// The submitted token is not a transaction this server will honour —
    /// unparseable, badly signed, signed for another app, or naming a product
    /// that is not ours.
    ///
    /// Reported verbatim, which is safe because the reason names nothing the
    /// caller does not already hold: a forger learns only that their forgery
    /// failed, and a client author debugging a real submission learns which of
    /// the four it was.
    #[error("{0}")]
    Rejected(#[from] VerificationError),

    /// The caller's row vanished between the identity layer creating it and this
    /// write. Unreachable short of a manual delete, and surfaced rather than
    /// answered with a free entitlement the client would then cache.
    #[error("no user row for the calling user")]
    Missing,

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Logs server-side faults before converting them.
///
/// Same rule as the other features: the client receives an opaque `internal`
/// status, so a silent conversion would leave the failure unreproducible from
/// outside the process. `Rejected` is the exception — it describes the caller's
/// own request, so it travels.
impl From<EntitlementError> for Status {
    fn from(error: EntitlementError) -> Self {
        match error {
            EntitlementError::Rejected(e) => {
                // At info, not warn: a rejected transaction is the expected
                // outcome of a sandbox build talking to a production server,
                // and the log level should not imply the server is unhealthy.
                tracing::info!(feature = "entitlement", error = %e, "rejected a submitted transaction");
                Self::invalid_argument(e.to_string())
            }
            EntitlementError::Missing => {
                tracing::error!(feature = "entitlement", "the calling user has no row");
                Self::internal("internal error")
            }
            EntitlementError::Database(e) => {
                tracing::error!(feature = "entitlement", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
