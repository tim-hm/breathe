//! Technique errors and their gRPC status mapping.

use tonic::Status;

#[derive(Debug, thiserror::Error)]
pub enum TechniqueError {
    /// A technique with no phase rows. The foreign key and the seed's own
    /// invariant make this unreachable, so reaching it means the schema changed
    /// under the read path — surfaced as `internal`, not silently dropped.
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
