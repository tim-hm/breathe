//! Entitlement SQL — two columns on `users`, and nothing else.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;

/// When the caller's Plus period ends, if they ever bought one.
///
/// `None` covers both "never subscribed" and "the column is null", which are
/// the same thing — the distinction the schema keeps is between a null and a
/// past date, and reading a past date back is what lets an expiry be honoured
/// without a job that clears it.
pub async fn find_plus_until(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<DateTime<Utc>>, EntitlementError> {
    let plus_until = sqlx::query_scalar!("SELECT plus_until FROM users WHERE id = $1", user_id)
        .fetch_optional(pool)
        .await?
        .ok_or(EntitlementError::Missing)?;

    Ok(plus_until)
}

/// Records what a verified transaction grants, returning the expiry as stored.
///
/// `GREATEST` rather than an assignment, and that is what makes resubmission
/// safe: the client submits whatever `StoreKit` hands it on every launch, and
/// `Transaction.updates` and `currentEntitlements` have no ordering between
/// them, so an older transaction arriving after a newer one is ordinary rather
/// than a bug. Assigning would let it shorten a subscription that had already
/// renewed. `GREATEST` ignores nulls, so the first purchase needs no special
/// case.
pub async fn record_purchase(
    pool: &PgPool,
    user_id: Uuid,
    original_transaction_id: &str,
    expires_at: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>, EntitlementError> {
    let plus_until = sqlx::query_scalar!(
        "UPDATE users
            SET plus_until = GREATEST(plus_until, $3),
                app_store_original_transaction_id = $2,
                updated_at = now()
          WHERE id = $1
        RETURNING plus_until",
        user_id,
        original_transaction_id,
        expires_at
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(plus_until)
}

/// Ends the entitlement a refunded transaction paid for.
///
/// Guarded on the transaction id inside the statement rather than in a `WHERE`
/// clause, so the row always comes back and the caller learns the resulting
/// expiry either way. The guard matters: `Transaction.updates` delivers a
/// revocation for whatever the person bought, which is not necessarily the
/// subscription this row is currently living on.
pub async fn revoke_purchase(
    pool: &PgPool,
    user_id: Uuid,
    original_transaction_id: &str,
) -> Result<Option<DateTime<Utc>>, EntitlementError> {
    let plus_until = sqlx::query_scalar!(
        "UPDATE users
            SET plus_until = CASE
                  WHEN app_store_original_transaction_id = $2 THEN NULL
                  ELSE plus_until
                END,
                updated_at = now()
          WHERE id = $1
        RETURNING plus_until",
        user_id,
        original_transaction_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(plus_until)
}
