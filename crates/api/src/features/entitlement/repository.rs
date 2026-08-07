//! Entitlement SQL — five columns on `users`, and nothing else.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;
use super::types::SubscriptionTier;

/// The subscription columns of one `users` row.
pub struct EntitlementRow {
    /// Which product the row holds, whether or not it has run out. `None`
    /// exactly when `subscription_until` is `None`, which the
    /// `users_subscription_is_whole` constraint guarantees.
    pub subscription_tier: Option<SubscriptionTier>,

    /// When it ends, whether or not it already has. The distinction the schema
    /// keeps is between a null and a past date, and reading a past date back is
    /// what lets an expiry be honoured without a job that clears it.
    pub subscription_until: Option<DateTime<Utc>>,

    /// The subscription this row is currently living on, which is what makes a
    /// revocation attributable to it.
    pub original_transaction_id: Option<String>,
}

/// Who holds one App Store transaction, and on what terms.
///
/// Read before a purchase is written, because a transaction is bound to a single
/// identity and this is the row that says which — see
/// `service::claim`.
pub struct TransactionHolder {
    pub user_id: Uuid,

    /// Whether the holder still has a grant from this transaction. `false` means
    /// it was revoked: a refund clears the tier and the expiry while leaving the
    /// binding, so a refunded transaction is frozen to the identity that was
    /// refunded and cannot be carried anywhere else.
    pub granted: bool,

    /// When this holder claimed it. `None` for a row bound before the column
    /// existed, which reads as "long ago".
    pub claimed_at: Option<DateTime<Utc>>,
}

pub async fn find_entitlement(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<EntitlementRow, EntitlementError> {
    let row = sqlx::query_as!(
        EntitlementRow,
        r#"SELECT
            subscription_tier AS "subscription_tier?: SubscriptionTier",
            subscription_until,
            app_store_original_transaction_id AS original_transaction_id
           FROM users
          WHERE id = $1"#,
        user_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(row)
}

/// Finds the identity a transaction is bound to, if any identity is.
///
/// At most one row can answer, which the
/// `users_app_store_original_transaction_id_key` constraint is what guarantees.
pub async fn find_transaction_holder(
    pool: &PgPool,
    original_transaction_id: &str,
) -> Result<Option<TransactionHolder>, EntitlementError> {
    let holder = sqlx::query_as!(
        TransactionHolder,
        r#"SELECT
            id AS user_id,
            subscription_tier IS NOT NULL AS "granted!",
            subscription_claimed_at AS claimed_at
           FROM users
          WHERE app_store_original_transaction_id = $1"#,
        original_transaction_id
    )
    .fetch_optional(pool)
    .await?;

    Ok(holder)
}

/// Writes what one verified transaction says onto the row, returning the row as
/// stored.
///
/// The single write path, and a revocation goes through it with `grant` set to
/// `None` — because a refund is not a different kind of write, it is a
/// transaction that happens to grant nothing. One statement therefore carries
/// the whole rule:
///
/// - **The row moves together**, because the tier and the expiry describe one
///   purchase. An upgrade from Plus to Coach mid-month issues a Coach
///   transaction whose expiry is *earlier* than the Plus period it replaced, so
///   a rule that kept the later expiry — which is what M8 did, with `GREATEST` —
///   would leave somebody paying for Coach and holding Plus.
/// - **Only forwards**, because the client resubmits whatever `StoreKit` hands
///   it and `Transaction.updates` and `currentEntitlements` have no ordering
///   between them. `signedDate` is the one field that orders them correctly:
///   Apple signs the truth at a moment, and the most recently signed transaction
///   for a subscription group is that group's current state.
///
/// A revocation therefore leaves `subscription_signed_at` set to its own
/// `signedDate` rather than nulling it. Nulling it reopened the guard to *any*
/// signedDate, including the pre-refund transaction the client still holds and
/// which verifies perfectly — its payload carries no `revocationDate` — so a
/// refund could be undone by resubmitting the purchase it refunded. The one
/// statement that does null it is [`release_transaction`], which gives up the
/// binding as well and so leaves nothing for a stale submission to win against.
///
/// `subscription_claimed_at` moves with every write, revocations included. That
/// costs nothing: it gates transfers, and a revoked transaction is not
/// transferable at all.
///
/// A submission that loses the comparison changes nothing and is not an error —
/// it is what a client sending the *same* transaction again gets, which it does
/// on every launch, so it is the ordinary path rather than the exceptional one.
/// That is why the `UNION ALL` is here rather than a second call: the caller has
/// to be told what the row holds either way, and paying two round trips for the
/// common case to save a CTE would be the wrong trade.
pub async fn apply_transaction(
    pool: &PgPool,
    user_id: Uuid,
    original_transaction_id: &str,
    grant: Option<(SubscriptionTier, DateTime<Utc>)>,
    signed_at: DateTime<Utc>,
) -> Result<EntitlementRow, EntitlementError> {
    let (tier, until) = grant.unzip();

    let row = sqlx::query_as!(
        EntitlementRow,
        r#"WITH moved AS (
             UPDATE users
                SET subscription_tier = $2,
                    subscription_until = $3,
                    app_store_original_transaction_id = $4,
                    subscription_signed_at = $5,
                    subscription_claimed_at = now(),
                    updated_at = now()
              WHERE id = $1
                AND (subscription_signed_at IS NULL OR subscription_signed_at < $5)
             RETURNING subscription_tier, subscription_until,
                       app_store_original_transaction_id
           )
           SELECT
             subscription_tier AS "subscription_tier?: SubscriptionTier",
             subscription_until,
             app_store_original_transaction_id AS original_transaction_id
           FROM moved
           UNION ALL
           SELECT
             subscription_tier AS "subscription_tier?: SubscriptionTier",
             subscription_until,
             app_store_original_transaction_id AS original_transaction_id
           FROM users
          WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM moved)"#,
        user_id,
        tier as Option<SubscriptionTier>,
        until,
        original_transaction_id,
        signed_at,
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(row)
}

/// Unbinds a transaction from the row holding it, so another identity may claim
/// it.
///
/// Clears the binding and the grant together: half a release would leave a row
/// entitled by a transaction it no longer holds, which is the state
/// [`find_transaction_holder`] reads as a revocation. Whether the release is
/// allowed at all is `service::claim`'s decision.
pub async fn release_transaction(pool: &PgPool, user_id: Uuid) -> Result<(), EntitlementError> {
    sqlx::query!(
        r#"UPDATE users
              SET subscription_tier = NULL,
                  subscription_until = NULL,
                  subscription_signed_at = NULL,
                  subscription_claimed_at = NULL,
                  app_store_original_transaction_id = NULL,
                  updated_at = now()
            WHERE id = $1"#,
        user_id
    )
    .execute(pool)
    .await?;

    Ok(())
}
