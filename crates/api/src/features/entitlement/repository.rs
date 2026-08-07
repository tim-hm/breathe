//! Entitlement SQL — two columns on `users`, and nothing else.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;

/// The two entitlement columns of one `users` row.
pub struct EntitlementRow {
    /// When the Plus period ends, whether or not it already has. `None` covers
    /// both "never subscribed" and "the column is null", which are the same
    /// thing — the distinction the schema keeps is between a null and a past
    /// date, and reading a past date back is what lets an expiry be honoured
    /// without a job that clears it.
    pub plus_until: Option<DateTime<Utc>>,

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
        "SELECT plus_until, app_store_original_transaction_id AS original_transaction_id
           FROM users
          WHERE id = $1",
        user_id
    )
    .fetch_optional(pool)
    .await?
    .ok_or(EntitlementError::Missing)?;

    Ok(row)
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

/// Ends the entitlement, for a refund the service has already attributed to the
/// subscription this row holds.
pub async fn clear_purchase(pool: &PgPool, user_id: Uuid) -> Result<(), EntitlementError> {
    let affected = sqlx::query!(
        "UPDATE users SET plus_until = NULL, updated_at = now() WHERE id = $1",
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
