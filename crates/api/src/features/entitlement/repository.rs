//! Entitlement SQL — four columns on `users`, and nothing else.
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
/// it is the ordinary result of a client sending last month's transaction after
/// this month's, which it does on every launch.
pub async fn record_purchase(
    pool: &PgPool,
    user_id: Uuid,
    transaction: &RecordedPurchase<'_>,
) -> Result<EntitlementRow, EntitlementError> {
    let row = sqlx::query_as!(
        EntitlementRow,
        r#"UPDATE users
              SET subscription_tier = $2,
                  subscription_until = $3,
                  app_store_original_transaction_id = $4,
                  subscription_signed_at = $5,
                  updated_at = now()
            WHERE id = $1
              AND (subscription_signed_at IS NULL OR subscription_signed_at < $5)
        RETURNING
            subscription_tier AS "subscription_tier?: SubscriptionTier",
            subscription_until,
            app_store_original_transaction_id AS original_transaction_id"#,
        user_id,
        transaction.tier as SubscriptionTier,
        transaction.expires_at,
        transaction.original_transaction_id,
        transaction.signed_at,
    )
    .fetch_optional(pool)
    .await?;

    match row {
        Some(row) => Ok(row),
        // The `WHERE` refused it as stale. Reading back is not a second attempt
        // at the same write — it is how the caller learns what the newer
        // transaction had already put there, which is what the response has to
        // carry.
        None => find_entitlement(pool, user_id).await,
    }
}

/// One verified purchase, in the shape the statement above writes.
///
/// A struct rather than four positional parameters, because two of them are
/// timestamps and the compiler cannot tell an expiry from a signing date.
pub struct RecordedPurchase<'a> {
    pub tier: SubscriptionTier,
    pub expires_at: DateTime<Utc>,
    pub signed_at: DateTime<Utc>,
    pub original_transaction_id: &'a str,
}

/// Ends the subscription, for a refund the service has already attributed to
/// the one this row holds.
///
/// Clears the signing date along with the rest, so a person who is refunded and
/// then buys again is not blocked by the timestamp of the purchase they no
/// longer have.
pub async fn clear_purchase(pool: &PgPool, user_id: Uuid) -> Result<(), EntitlementError> {
    let affected = sqlx::query!(
        "UPDATE users
            SET subscription_tier = NULL,
                subscription_until = NULL,
                subscription_signed_at = NULL,
                updated_at = now()
          WHERE id = $1",
        user_id
    )
    .execute(pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(EntitlementError::Missing);
    }

    Ok(())
}
