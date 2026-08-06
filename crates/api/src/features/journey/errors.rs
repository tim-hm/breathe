//! Journey errors and their gRPC status mapping.

use tonic::Status;

#[derive(Debug, thiserror::Error)]
pub enum JourneyError {
    /// The client sent something the contract admits but the domain does not —
    /// an unparseable session id, a batch past the limit, a board nobody asked
    /// for. Reported verbatim: the caller can fix it, and an opaque message
    /// would leave them guessing which of a hundred sessions was wrong.
    #[error("{0}")]
    Invalid(String),

    /// The caller asked for the age-band board without having said when they
    /// were born. Its own variant rather than an `Invalid`, because the request
    /// was well-formed — what is missing is state, and the client's response is
    /// to offer the question rather than to correct a field.
    #[error("set a birth year band before asking for the age band board")]
    AgeBandUnset,

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    /// The band lookup belongs to `profile`, which owns the column. Its errors
    /// are the same two shapes as this feature's own, so they are carried rather
    /// than re-described.
    #[error(transparent)]
    Profile(#[from] crate::features::profile::errors::ProfileError),
}

/// Logs server-side faults before converting them.
///
/// Same rule as the other features: an `internal` status tells the client
/// nothing, so the detail has to be recorded here or it is lost.
impl From<JourneyError> for Status {
    fn from(error: JourneyError) -> Self {
        match error {
            JourneyError::Invalid(message) => Self::invalid_argument(message),
            JourneyError::AgeBandUnset => Self::failed_precondition(
                "set a birth year band before asking for the age band board",
            ),
            JourneyError::Profile(e) => e.into(),
            JourneyError::Database(e) => {
                tracing::error!(feature = "journey", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
