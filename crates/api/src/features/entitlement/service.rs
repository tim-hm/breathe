//! Business logic — decides what a verified transaction is worth, and converts
//! both ways across the proto boundary.
//!
//! Receives explicit dependencies (`&PgPool`, `&dyn TransactionVerifier`), never
//! `Arc<AppState>`, and contains zero raw queries.

use chrono::Utc;
use sqlx::PgPool;
use uuid::Uuid;

use super::errors::EntitlementError;
use super::repository;
use super::types::{Entitlement, Tier};
use super::verifier::TransactionVerifier;
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

    let plus_until = if transaction.revoked_at.is_some() {
        repository::revoke_purchase(pool, user_id, &transaction.original_transaction_id).await?
    } else {
        repository::record_purchase(
            pool,
            user_id,
            &transaction.original_transaction_id,
            transaction.expires_at,
        )
        .await?
    };

    Ok(pb::SubmitAppStoreTransactionResponse {
        entitlement: Some(to_proto(Entitlement::resolve(plus_until, Utc::now()))),
    })
}

pub async fn get_entitlement(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<pb::GetEntitlementResponse, EntitlementError> {
    let plus_until = repository::find_plus_until(pool, user_id).await?;

    Ok(pb::GetEntitlementResponse {
        entitlement: Some(to_proto(Entitlement::resolve(plus_until, Utc::now()))),
    })
}

/// The caller's tier, for a feature that is deciding what to spend on them.
///
/// Fails to `Free` rather than propagating, and that is the whole reason it is
/// not just `find_plus_until`: the callers are cost controls, and an unreachable
/// database must not be a way to be treated as a subscriber. It also must not
/// take the feature down — `assistant` answers from its rules when this says
/// `Free`, which is a worse answer than the caller paid for but still an answer.
pub async fn tier(pool: &PgPool, user_id: Uuid) -> Tier {
    match repository::find_plus_until(pool, user_id).await {
        Ok(plus_until) => Entitlement::resolve(plus_until, Utc::now()).tier,
        Err(error) => {
            tracing::error!(feature = "entitlement", %error, "could not read the caller's tier; treating them as free");
            Tier::Free
        }
    }
}

fn to_proto(entitlement: Entitlement) -> pb::Entitlement {
    let tier = match entitlement.tier {
        Tier::Free => pb::EntitlementTier::Free,
        Tier::Plus => pb::EntitlementTier::Plus,
    };

    pb::Entitlement {
        tier: tier as i32,
        expires_at: entitlement.expires_at.map(|at| prost_types::Timestamp {
            seconds: at.timestamp(),
            // A leap second reports more than a billion subsecond nanoseconds,
            // which the proto type cannot carry; clamping loses at most that
            // one second.
            nanos: i32::try_from(at.timestamp_subsec_nanos()).unwrap_or(999_999_999),
        }),
    }
}
