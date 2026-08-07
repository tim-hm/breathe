//! Business logic — decides what a verified transaction is worth, and converts
//! both ways across the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`, `&dyn TransactionVerifier`), never
//! `Arc<AppState>`, and contains zero raw queries.

use chrono::Utc;
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;
use super::repository::{self, EntitlementRow, RecordedPurchase};
use super::types::{Entitlement, Tier};
use super::verifier::{TransactionVerifier, VerifiedTransaction};
use crate::proto::breathe::v1 as pb;

/// Verifies a submitted transaction and stores what it grants.
///
/// Three outcomes, and only the first is an error: the token does not verify;
/// the token verifies and revokes; the token verifies and entitles. The middle
/// one is a refund, which is not a failure of anything — the caller is simply
/// not a subscriber any more, and the response says so.
pub async fn submit_transaction(
    pool: &PgPool,
    verifier: &dyn TransactionVerifier,
    user_id: Uuid,
    signed_transaction: &str,
) -> Result<pb::SubmitAppStoreTransactionResponse, EntitlementError> {
    let transaction = verifier.verify(signed_transaction)?;

    let stored = if transaction.revoked_at.is_some() {
        revoke(pool, user_id, &transaction).await?
    } else {
        repository::record_purchase(
            pool,
            user_id,
            &RecordedPurchase {
                tier: transaction.tier,
                expires_at: transaction.expires_at,
                signed_at: transaction.signed_at,
                original_transaction_id: &transaction.original_transaction_id,
            },
        )
        .await?
    };

    Ok(pb::SubmitAppStoreTransactionResponse {
        entitlement: Some(to_proto(resolve(&stored))),
    })
}

/// Ends the entitlement, but only if the refund is for the subscription this
/// row is actually living on.
///
/// The guard matters and is here rather than in the `UPDATE`'s `WHERE` clause
/// because it is a rule rather than a query: `Transaction.updates` delivers a
/// revocation for whatever the person bought, and somebody who cancelled last
/// year's subscription and started a new one must not lose the new one to the
/// old one's refund arriving late.
async fn revoke(
    pool: &PgPool,
    user_id: Uuid,
    transaction: &VerifiedTransaction,
) -> Result<EntitlementRow, EntitlementError> {
    let stored = repository::find_entitlement(pool, user_id).await?;

    if stored.original_transaction_id.as_deref() != Some(&transaction.original_transaction_id) {
        return Ok(stored);
    }

    repository::clear_purchase(pool, user_id).await?;

    Ok(EntitlementRow {
        subscription_tier: None,
        subscription_until: None,
        original_transaction_id: stored.original_transaction_id,
    })
}

pub async fn get_entitlement(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<pb::GetEntitlementResponse, EntitlementError> {
    let stored = repository::find_entitlement(pool, user_id).await?;

    Ok(pb::GetEntitlementResponse {
        entitlement: Some(to_proto(resolve(&stored))),
    })
}

/// The stored row read against the clock, which is the only place the two are
/// put together — the row is what the database holds and an [`Entitlement`] is
/// what it means right now.
fn resolve(row: &EntitlementRow) -> Entitlement {
    Entitlement::resolve(row.subscription_tier, row.subscription_until, Utc::now())
}

fn to_proto(entitlement: Entitlement) -> pb::Entitlement {
    let tier = match entitlement.tier() {
        Tier::Free => pb::EntitlementTier::Free,
        Tier::Plus => pb::EntitlementTier::Plus,
        Tier::Coach => pb::EntitlementTier::Coach,
    };

    pb::Entitlement {
        tier: tier as i32,
        expires_at: entitlement.expires_at().map(|at| prost_types::Timestamp {
            seconds: at.timestamp(),
            // A leap second reports more than a billion subsecond nanoseconds,
            // which the proto type cannot carry; clamping loses at most that
            // one second.
            nanos: i32::try_from(at.timestamp_subsec_nanos()).unwrap_or(999_999_999),
        }),
    }
}
