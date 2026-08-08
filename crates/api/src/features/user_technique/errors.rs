//! User technique errors and their gRPC status mapping.

use tonic::Status;

/// Why an authored technique could not be stored or served.
#[derive(Debug, thiserror::Error)]
pub enum UserTechniqueError {
    /// The draft is well-formed protobuf describing something the domain will
    /// not accept — a phase outside the seeded range, a stage of no cycles, a
    /// goal this server has no case for. Reported verbatim, naming the phase or
    /// field: the person is composing, and "invalid" without a location leaves
    /// them dragging dials to find which one the server disliked.
    #[error("{0}")]
    Invalid(String),

    /// The caller already holds as many techniques as they may. Its own variant
    /// rather than an `Invalid`, because nothing about the draft is wrong —
    /// what they have to do is delete one, which is a different sentence and a
    /// different status.
    #[error("{0}")]
    TooMany(String),

    /// No technique with that id belongs to this caller. One variant covers both
    /// "does not exist" and "is somebody else's" on purpose: distinguishing them
    /// would answer whether an id exists to a caller who cannot read it.
    #[error("no technique with that id")]
    NotFound,

    /// A stored technique that does not fit the wire — a stage with no phases, a
    /// negative duration. The `CHECK`s and foreign keys make every one of these
    /// unreachable, so reaching one means the schema changed under the read
    /// path. Surfaced as `internal` rather than trimmed: a technique silently
    /// short of a phase is one somebody's session plays wrong.
    #[error("{0}")]
    Inconsistent(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Logs server-side faults before converting them.
///
/// Same rule as the other features: an `internal` status tells the client
/// nothing, so the detail has to be recorded here or it is lost.
impl From<UserTechniqueError> for Status {
    fn from(error: UserTechniqueError) -> Self {
        match error {
            UserTechniqueError::Invalid(message) => Self::invalid_argument(message),
            UserTechniqueError::TooMany(message) => Self::resource_exhausted(message),
            UserTechniqueError::NotFound => Self::not_found("no technique with that id"),
            UserTechniqueError::Inconsistent(message) => {
                tracing::error!(feature = "user_technique", error = %message, "inconsistent technique");
                Self::internal("internal error")
            }
            UserTechniqueError::Database(e) => {
                tracing::error!(feature = "user_technique", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
