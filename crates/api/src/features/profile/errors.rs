//! Profile errors and their gRPC status mapping.

use tonic::Status;

#[derive(Debug, thiserror::Error)]
pub enum ProfileError {
    /// The client sent something the contract admits but the domain does not —
    /// an unspecified goal, a note past the length the column accepts. Reported
    /// verbatim, unlike the faults below: the caller can fix it, and an opaque
    /// message would leave them guessing which field.
    #[error("{0}")]
    Invalid(String),

    /// The caller's row vanished between the identity layer creating it and this
    /// read. Unreachable short of a manual delete, and surfaced rather than
    /// papered over with an empty profile the client would then display.
    #[error("no profile row for the calling user")]
    Missing,

    /// Every suffixed variant of a requested display name is taken. Reported to
    /// the caller rather than hidden, because the fix is theirs: pick a
    /// different name.
    #[error("that display name and every variant of it are taken — try another")]
    DisplayNameUnavailable,

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

/// Logs server-side faults before converting them.
///
/// Same rule as `technique::errors`: the client receives an opaque `internal`
/// status, so a silent conversion would leave the failure unreproducible from
/// outside the process. `Invalid` and `DisplayNameUnavailable` are the
/// exceptions — both describe the caller's own request and name something they
/// can change, so they travel.
impl From<ProfileError> for Status {
    fn from(error: ProfileError) -> Self {
        match error {
            ProfileError::Invalid(message) => Self::invalid_argument(message),
            ProfileError::DisplayNameUnavailable => {
                Self::already_exists("that display name and every variant of it are taken")
            }
            ProfileError::Missing => {
                tracing::error!(feature = "profile", "the calling user has no row");
                Self::internal("internal error")
            }
            ProfileError::Database(e) => {
                tracing::error!(feature = "profile", error = %e, "database error");
                Self::internal("internal error")
            }
        }
    }
}
