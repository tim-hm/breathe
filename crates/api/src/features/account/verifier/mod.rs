//! The seam every Sign in with Apple credential arrives through.
//!
//! One trait and two implementations, in the shape `entitlement::verifier`
//! established: [`apple`] checks a real signature against Apple's published
//! keys, and the integration tests script one. That split is what makes the rest
//! of the feature — the binding, the merge, the transaction it runs in —
//! testable with nothing Apple signed and no network.
//!
//! Unlike `TransactionVerifier`, this one is **async**, and the difference is
//! not stylistic. An App Store transaction carries its own certificate chain, so
//! verifying it is arithmetic over bytes the caller already holds. An identity
//! token carries only a key id, and the key itself is fetched from Apple — so
//! there really is a round trip to await, however rarely it happens.

pub mod apple;

pub use self::apple::AppleIdentityVerifier;

/// Who the caller proved they are.
///
/// One field, because one is all a binding needs. Apple's token also carries an
/// email and a `email_verified` flag, and both are deliberately left behind:
/// nothing here sends mail, and a private-relay address is a fact about Apple's
/// forwarding rather than about the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    /// Apple's `sub`. Stable for one Apple ID against one developer team and
    /// opaque outside it, which is exactly what makes it usable as the key a
    /// person's history is filed under.
    pub apple_user_id: String,
}

/// Why a submitted identity token proved nothing.
///
/// Three variants for the same reason `entitlement` has three: they mean
/// different things about the caller — a client bug, a forgery, and a build
/// pointed at the wrong app — and the message travels, so the distinction is
/// what a client author sees when a sign-in fails.
#[derive(Debug, thiserror::Error)]
pub enum VerificationError {
    /// Not a JWT, or a JWT whose parts do not decode: wrong segment count,
    /// invalid base64url, a header or payload that is not the JSON this expects.
    #[error("the identity token is malformed: {0}")]
    Malformed(String),

    /// The bytes parsed, and the signature is not Apple's — an unknown key id, a
    /// signature that does not verify, an algorithm other than the RS256 Apple
    /// signs with, an issuer that is not Apple, or a token that has expired.
    #[error("the identity token is not a valid Apple credential: {0}")]
    Untrusted(String),

    /// Genuinely Apple's, and issued for somebody else's app. The one rejection
    /// that is nobody's bug: a build whose bundle id does not match the one this
    /// server was compiled for produces exactly this.
    #[error("the identity token is not for this app: {0}")]
    NotOurs(String),

    /// Apple's key endpoint could not be reached or did not answer with a key
    /// set. This server's problem rather than the caller's, and separated from
    /// the three above so it can be logged and reported as such — telling
    /// somebody their credential is invalid when the truth is that we could not
    /// check it would have them re-authenticating against an outage.
    #[error("Apple's signing keys are unavailable: {0}")]
    Unavailable(String),
}

/// What the account feature needs from a credential checker, and nothing else.
///
/// `tonic::async_trait` rather than a native `async fn`, matching
/// `assistant::model::ModelClient`: async functions in traits are not
/// `dyn`-compatible, and this trait exists to be used through `dyn` so that the
/// composition root picks the implementation at startup and no test can reach
/// Apple by accident.
#[tonic::async_trait]
pub trait IdentityTokenVerifier: Send + Sync {
    /// Checks `identity_token` and returns the Apple account it names.
    ///
    /// Every check is in here rather than split with the caller, for the reason
    /// `TransactionVerifier::verify` gives: "verified" has to mean one thing —
    /// Apple signed it, for this app, and it has not expired. A service that had
    /// to remember to check the audience afterwards would eventually forget, and
    /// the failure would be silent.
    async fn verify(&self, identity_token: &str) -> Result<VerifiedIdentity, VerificationError>;
}
