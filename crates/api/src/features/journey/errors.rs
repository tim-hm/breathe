//! Journey errors and their gRPC status mapping.

use tonic::Status;

/// Why a journey call could not be answered.
///
/// The variants that describe the caller's own request travel to them verbatim;
/// this server's own faults travel as `internal` with the detail left in the
/// log. That split is the whole reason this enum exists rather than a bare
/// `Status`.
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

    /// A stored aggregate that does not fit the field the wire carries it in —
    /// a negative streak, a rank past four billion. The `CHECK`s on both tables
    /// make every one of these unreachable, so reaching one means the schema
    /// changed under the read path. Surfaced as `internal` rather than clamped:
    /// a board silently one row short, or a total silently zero, is
    /// unfalsifiable from a client.
    #[error("{0}")]
    Inconsistent(String),

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
            JourneyError::Inconsistent(message) => {
                tracing::error!(feature = "journey", error = %message, "inconsistent aggregate");
                Self::internal("internal error")
            }
            JourneyError::Database(e) => {
                tracing::error!(feature = "journey", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
