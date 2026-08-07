//! Assistant errors and their gRPC status mapping.
//!
//! Conspicuously short, because the model failing is not one of them: an
//! unreachable model, a tripped breaker, and an exhausted quota all produce a
//! successful response flagged `FALLBACK`. What remains here is the caller
//! asking for something that does not exist, and the database being unreachable
//! — which is fatal, since the fallback is derived from the profile and the
//! catalogue.

use tonic::Status;

use crate::features::entitlement::errors::EntitlementError;
use crate::features::journey::errors::JourneyError;
use crate::features::profile::errors::ProfileError;
use crate::features::technique::errors::TechniqueError;

/// Why the assistant could not answer at all.
///
/// Short by design: the model failing is not one of these. An unreachable
/// provider, a tripped breaker and an exhausted quota all produce a successful
/// response flagged `FALLBACK`, so what is left is a slug that does not exist
/// and a database that cannot be read — and the second is fatal precisely
/// because the fallback is derived from what the database holds.
#[derive(Debug, thiserror::Error)]
pub enum AssistantError {
    /// The caller asked to have a technique explained that the catalogue does
    /// not hold. Reported verbatim: it names the slug they sent, which is the
    /// one thing they can act on.
    #[error("{0}")]
    UnknownTechnique(String),

    /// The chat request itself was malformed — an empty or over-long message,
    /// an over-long history turn, or a turn that does not say who spoke.
    /// Reported verbatim: only a client bug produces one, and the message is
    /// what names the bug.
    #[error("{0}")]
    InvalidChat(String),

    /// The catalogue came back empty, so there is nothing to recommend and no
    /// fallback to derive. Unreachable while the seed runs on every migration,
    /// and surfaced rather than answered with an empty list.
    #[error("the technique catalogue is empty")]
    EmptyCatalogue,

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    /// Reading the caller's profile failed. Folded in rather than re-modelled:
    /// the profile feature owns what can go wrong with a profile, and repeating
    /// its variants here would be two places to keep in step.
    #[error("profile error: {0}")]
    Profile(#[from] ProfileError),

    /// Reading the catalogue failed, likewise.
    #[error("technique error: {0}")]
    Technique(#[from] TechniqueError),

    /// Reading the caller's practice snapshot failed, likewise.
    #[error("journey error: {0}")]
    Journey(#[from] JourneyError),

    /// Reading what the caller is entitled to failed. Fatal rather than read as
    /// "free", because it is the same row and the same connection the profile
    /// read above needs — a database that cannot answer this one has already
    /// failed the call.
    #[error("entitlement error: {0}")]
    Entitlement(#[from] EntitlementError),
}

/// Logs server-side faults before converting them.
///
/// Same rule as the other features: the client receives an opaque `internal`
/// status, so a silent conversion would leave the failure unreproducible from
/// outside the process.
impl From<AssistantError> for Status {
    fn from(error: AssistantError) -> Self {
        match error {
            AssistantError::UnknownTechnique(message) => Self::not_found(message),
            AssistantError::InvalidChat(message) => Self::invalid_argument(message),
            AssistantError::EmptyCatalogue => {
                tracing::error!(feature = "assistant", "the catalogue is empty");
                Self::internal("internal error")
            }
            AssistantError::Database(e) => {
                tracing::error!(feature = "assistant", error = %e, "database error");
                Self::internal("internal error")
            }
            AssistantError::Profile(e) => e.into(),
            AssistantError::Technique(e) => e.into(),
            AssistantError::Journey(e) => e.into(),
            AssistantError::Entitlement(e) => e.into(),
        }
    }
}
