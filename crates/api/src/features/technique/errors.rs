//! Technique errors and their gRPC status mapping.

use tonic::Status;

/// Why the catalogue could not be served.
///
/// Neither variant is the caller's doing — this service takes no identity and
/// its requests carry nothing to get wrong — so both travel as `internal` and
/// the detail stays in the log.
#[derive(Debug, thiserror::Error)]
pub enum TechniqueError {
    /// A technique with no stages, or a stage with no phases. The foreign keys
    /// and the seed's own invariants make both unreachable, so reaching one
    /// means the schema changed under the read path — surfaced as `internal`,
    /// not silently dropped.
    #[error("{0}")]
    Inconsistent(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Logs server-side faults before converting them.
///
/// The client only ever receives an opaque `internal` status, so a conversion
/// that stays silent leaves the failure unreproducible from outside the process.
/// The sqlx error is deliberately not forwarded — it can carry table and column
/// names, and the log is where that detail belongs.
impl From<TechniqueError> for Status {
    fn from(error: TechniqueError) -> Self {
        match error {
            TechniqueError::Inconsistent(message) => {
                tracing::error!(feature = "technique", error = %message, "inconsistent catalogue");
                Self::internal("internal error")
            }
            TechniqueError::Database(e) => {
                tracing::error!(feature = "technique", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
