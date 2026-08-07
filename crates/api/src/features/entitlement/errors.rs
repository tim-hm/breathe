//! Entitlement errors and their gRPC status mapping.

use tonic::Status;

use super::verifier::VerificationError;

/// Why a submission bought nothing, or why a read could not be answered.
///
/// Three of the five describe the caller's own request and travel to them
/// verbatim; the other two are this server's faults and travel as `internal`.
/// The split is the whole reason this enum exists rather than a bare `Status`.
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

    /// The token is larger than any real `jwsRepresentation`, and was refused
    /// before the verifier read a byte of it.
    ///
    /// Carries the bound so a client author sees the number rather than having
    /// to guess it — there is nothing to leak, since the limit is a property of
    /// this server and not of anybody's data.
    #[error("the signed transaction is longer than {0} bytes")]
    TooLarge(usize),

    /// The transaction is bound to another identity and may not move to this one
    /// yet.
    ///
    /// A signed transaction names an Apple account and no breathe identity, so
    /// without this a token copied off a device entitles every UUID that submits
    /// it. Told to the caller plainly: the honest case is a reinstall, and the
    /// person needs to know the purchase is held rather than broken.
    #[error("the signed transaction is claimed by another installation")]
    Claimed,

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
/// outside the process. The three rejections are the exception — each describes
/// the caller's own request, so each travels.
impl From<EntitlementError> for Status {
    fn from(error: EntitlementError) -> Self {
        match &error {
            EntitlementError::Rejected(e) => {
                // At debug, not warn: a rejected transaction is the expected
                // outcome of a sandbox build talking to a production server, and
                // the level should not imply the server is unhealthy. Not info
                // either — it fires once per submission, and the client submits
                // on every launch.
                tracing::debug!(feature = "entitlement", error = %e, "rejected a submitted transaction");
                Self::invalid_argument(e.to_string())
            }
            EntitlementError::TooLarge(bound) => {
                tracing::debug!(
                    feature = "entitlement",
                    bound,
                    "refused an oversized transaction"
                );
                Self::invalid_argument(error.to_string())
            }
            EntitlementError::Claimed => {
                tracing::debug!(
                    feature = "entitlement",
                    "refused a claim on a bound transaction"
                );
                Self::permission_denied(error.to_string())
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
