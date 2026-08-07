//! Entitlement SQL — four columns on `users`, and nothing else.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;
use super::types::SubscriptionTier;
use super::verifier::VerifiedTransaction;

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

/// Records what a verified transaction grants, returning the row as stored.
///
/// The whole subscription moves together, and only forwards in `signedDate`.
/// Both halves of that matter:
///
/// - **Together**, because the tier and the expiry describe one purchase. An
///   upgrade from Plus to Coach mid-month issues a Coach transaction whose
///   expiry is *earlier* than the Plus period it replaced, so a rule that kept
///   the later expiry — which is what M8 did, with `GREATEST` — would leave
///   somebody paying for Coach and holding Plus.
/// - **Only forwards**, because the client resubmits whatever `StoreKit` hands
///   it and `Transaction.updates` and `currentEntitlements` have no ordering
///   between them. `signedDate` is the one field that orders them correctly:
///   Apple signs the truth at a moment, and the most recently signed
///   transaction for a subscription group is that group's current state.
///
/// A submission that loses the comparison changes nothing and is not an error —
/// it is what a client sending the *same* transaction again gets, which it does
/// on every launch, so it is the ordinary path rather than the exceptional one.
/// That is why the `UNION ALL` is here rather than a second call: the caller has
/// to be told what the row holds either way, and paying two round trips for the
/// common case to save a CTE would be the wrong trade.
pub async fn record_purchase(
    pool: &PgPool,
    user_id: Uuid,
    transaction: &VerifiedTransaction,
) -> Result<EntitlementRow, EntitlementError> {
    let row = sqlx::query_as!(
        EntitlementRow,
        r#"WITH moved AS (
             UPDATE users
                SET subscription_tier = $2,
                    subscription_until = $3,
                    app_store_original_transaction_id = $4,
                    subscription_signed_at = $5,
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
        transaction.tier as SubscriptionTier,
        transaction.expires_at,
        transaction.original_transaction_id,
        transaction.signed_at,
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(row)
}

/// Ends the subscription, for a refund the service has already attributed to
/// the one this row holds.
///
/// Clears the signing date along with the rest, so a person who is refunded and
/// then buys again is not blocked by the timestamp of the purchase they no
/// longer have.
pub async fn clear_purchase(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<EntitlementRow, EntitlementError> {
    let row = sqlx::query_as!(
        EntitlementRow,
        r#"UPDATE users
              SET subscription_tier = NULL,
                  subscription_until = NULL,
                  subscription_signed_at = NULL,
                  updated_at = now()
            WHERE id = $1
        RETURNING
            subscription_tier AS "subscription_tier?: SubscriptionTier",
            subscription_until,
            app_store_original_transaction_id AS original_transaction_id"#,
        user_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(row)
}
