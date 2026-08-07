//! The seam every App Store transaction arrives through.
//!
//! One trait and two implementations: [`appstore`] checks a real signature, and
//! the integration tests script one. That split is what makes the whole feature
//! — the storage, the idempotency, the revocation path, the tier the assistant
//! reads — testable with no Apple-signed material and no network.
//!
//! Deliberately synchronous. Verification is a signature check over bytes the
//! caller already holds; there is nothing to await, and an `async fn` here would
//! promise a round-trip the design specifically avoids.

pub mod appstore;

use chrono::{DateTime, Utc};

pub use self::appstore::AppStoreVerifier;
use super::types::SubscriptionTier;

/// What a signed transaction asserts, once its signature has been checked
/// against Apple's root and its app and product confirmed as ours.
///
/// Only the fields something acts on. The payload carries a dozen more —
/// purchase date, quantity, storefront, environment — and every one of them
/// would be a field to keep in step with a contract Apple owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedTransaction {
    /// Stable across every renewal of one subscription, which is what makes a
    /// resubmission recognisable as the same purchase.
    pub original_transaction_id: String,

    /// Which product this is, resolved from the payload's `productId`. A
    /// `SubscriptionTier` rather than a `Tier` because a transaction is always
    /// a purchase — there is no free product to be a transaction for, and a
    /// `productId` naming neither of ours is rejected rather than mapped down.
    pub tier: SubscriptionTier,

    /// When this period ends. Not optional: an auto-renewable subscription
    /// always carries one, and a payload without it is not a transaction for a
    /// product this app sells — [`TransactionVerifier::verify`] rejects it
    /// rather than passing a `None` every caller would have to interpret.
    pub expires_at: DateTime<Utc>,

    /// When Apple signed this, which is what orders one submission against
    /// another.
    ///
    /// Carried out of the verifier because it is the only field that can order
    /// them correctly. The expiry cannot: upgrading Plus to Coach mid-month
    /// issues a Coach transaction whose expiry is *earlier* than the Plus period
    /// it replaced, so "keep the later expiry" would keep the subscription the
    /// person has just stopped paying for.
    pub signed_at: DateTime<Utc>,

    /// When Apple refunded or revoked it, if they did. `Some` means the
    /// transaction entitles nothing, however far in the future its expiry sits.
    pub revoked_at: Option<DateTime<Utc>>,
}

/// Why a submitted token bought nothing.
///
/// Three variants because they mean three different things about the caller —
/// a client bug, an attack, and a build pointed at the wrong app — and the
/// message travels to the client, so the distinction is what a developer sees
/// when a submission fails.
#[derive(Debug, thiserror::Error)]
pub enum VerificationError {
    /// Not a JWS at all, or a JWS whose parts do not decode: wrong segment
    /// count, invalid base64url, a header or payload that is not the JSON this
    /// expects.
    #[error("the signed transaction is malformed: {0}")]
    Malformed(String),

    /// The bytes parsed, and the signature does not lead back to Apple's root
    /// certificate. Also covers a chain that is well-formed but expired, and an
    /// algorithm other than the ES256 Apple signs with.
    #[error("the signed transaction is not signed by Apple: {0}")]
    Untrusted(String),

    /// Genuinely Apple's, and for somebody else's app or a product this build
    /// does not sell. The one rejection that is not a bug on either side: a
    /// development build with the wrong bundle id produces exactly this, and so
    /// does an old client still submitting a product that has been withdrawn.
    #[error("the signed transaction is not for this app: {0}")]
    NotOurs(String),
}

/// What the entitlement feature needs from a signature checker, and nothing
/// else.
///
/// A plain `trait` used through `dyn`, matching `assistant::model::ModelClient`:
/// the composition root picks the implementation at startup, and the service is
/// written against the trait so no test can reach a real certificate chain by
/// accident.
pub trait TransactionVerifier: Send + Sync {
    /// Checks `signed_transaction` and returns what it asserts.
    ///
    /// Every check is in here rather than split with the caller, because
    /// "verified" has to mean one thing: the signature leads to Apple's root,
    /// the app is this app, and the product is the one this app sells. A
    /// service that had to remember to check the bundle id afterwards would
    /// eventually forget.
    fn verify(&self, signed_transaction: &str) -> Result<VerifiedTransaction, VerificationError>;
}
