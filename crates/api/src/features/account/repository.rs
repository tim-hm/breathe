//! Account SQL — one column on `users`, and the merge a returning sign-in
//! performs.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts a user. What it does do that no other repository does is *delete*
//! one, which is why every statement below runs inside one transaction.

use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::errors::AccountError;
use crate::identity::UserId;

/// Binds `apple_user_id` to an identity and returns the one the device should
/// adopt.
///
/// Three cases, decided by which row — if any — already holds the Apple account:
///
/// - **Nobody holds it.** The caller's row takes it, and the caller keeps its
///   own id. This is a first sign-in.
/// - **The caller holds it.** Nothing to do. A client that signs in again on the
///   same installation gets its own id back rather than an error.
/// - **Another row holds it.** That row is this person's real history, so the
///   caller's is folded into it by [`merge`] and the device adopts its id.
///
/// One transaction over all three, with the holding row locked before anything
/// is read off it: two devices signing into one Apple account at the same moment
/// must not both decide they are the first, and `users.apple_user_id` being
/// `UNIQUE` turns the race that gets past the lock into a failed statement rather
/// than a second row.
pub async fn bind_apple_account(
    pool: &PgPool,
    caller: UserId,
    apple_user_id: &str,
) -> Result<Uuid, AccountError> {
    let mut tx = pool.begin().await?;

    let holder = sqlx::query_scalar!(
        "SELECT id FROM users WHERE apple_user_id = $1 FOR UPDATE",
        apple_user_id
    )
    .fetch_optional(&mut *tx)
    .await?;

    let adopted = match holder {
        Some(held_by) if held_by == caller.0 => held_by,
        Some(held_by) => {
            merge(&mut tx, caller, held_by).await?;
            held_by
        }
        None => {
            claim(&mut tx, caller, apple_user_id).await?;
            caller.0
        }
    };

    tx.commit().await?;

    Ok(adopted)
}

/// Writes the binding onto the caller's own row, which nobody else holds.
///
/// Reads the row's current binding first rather than writing behind a
/// `WHERE apple_user_id IS NULL`, because the two ways that write could affect no
/// rows — a missing row and a row bound to somebody else — mean entirely
/// different things to the caller and `rows_affected` cannot tell them apart.
async fn claim(
    tx: &mut Transaction<'_, Postgres>,
    caller: UserId,
    apple_user_id: &str,
) -> Result<(), AccountError> {
    let current = sqlx::query_scalar!(
        "SELECT apple_user_id FROM users WHERE id = $1 FOR UPDATE",
        caller.0
    )
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(AccountError::Missing)?;

    // The caller cannot be bound to *this* Apple account — the lookup that sent
    // us here found no row holding it — so any binding here is another one.
    if current.is_some() {
        return Err(AccountError::AlreadyBound);
    }

    sqlx::query!(
        "UPDATE users SET apple_user_id = $2, updated_at = now() WHERE id = $1",
        caller.0,
        apple_user_id
    )
    .execute(&mut **tx)
    .await?;

    Ok(())
}

/// Folds the anonymous identity `from` into the signed-in identity `into`, then
/// deletes it.
///
/// The device arrives carrying an id it minted on first launch and is signing in
/// to an Apple account that already has a row. Both may have history. The rule is
/// **reparent then delete**: `into`'s row survives with its own profile answers,
/// `from`'s children move onto it, and `from` goes. The device adopts `into`'s
/// id. The alternative — keeping `from` and moving the binding — would throw away
/// whichever history was older, which is the thing signing in exists to recover.
///
/// Three sub-rules, each following from the schema rather than from taste:
///
/// - **`sessions` and `bolt_scores`** reparent, skipping a row `into` already
///   has. Both are keyed `(user_id, client_<thing>_id)` over an id the *client*
///   minted, so a key held on both sides is one record that reached the server
///   twice — never two things that happened. Written as a `NOT EXISTS` guard
///   because `ON CONFLICT` belongs to `INSERT` and this is an `UPDATE`; the rows
///   it skips are left on `from` and go with the `ON DELETE CASCADE` below, which
///   is the same outcome by a shorter route than deleting them here.
/// - **`assistant_usage`** sums on a shared date. It is a spend limit, counted
///   per person per UTC day, so keeping `into`'s count would let signing in
///   launder whatever `from` had already spent — the same fan-out
///   `entitlement::service`'s `TRANSFER_COOLDOWN` exists to stop, reached by
///   another door.
/// - **Entitlements are not copied.** They are columns on `users` rather than a
///   child table, so deleting `from` releases its
///   `app_store_original_transaction_id` outright, and the client resubmits its
///   `StoreKit` transaction on every launch — `entitlement::service::claim` then
///   grants it to `into` against no holder at all. Copying them would mean
///   reasoning about `users_app_store_original_transaction_id_key` and the
///   transfer cooldown for an outcome the next launch produces by itself.
///
/// Every statement is in the caller's transaction. Half a merge is a person whose
/// sessions moved and whose breath-test history did not, with nothing left to
/// tell anyone it happened.
async fn merge(
    tx: &mut Transaction<'_, Postgres>,
    from: UserId,
    into: Uuid,
) -> Result<(), AccountError> {
    sqlx::query!(
        "UPDATE sessions AS moving
            SET user_id = $2
          WHERE moving.user_id = $1
            AND NOT EXISTS (
              SELECT 1 FROM sessions AS held
               WHERE held.user_id = $2
                 AND held.client_session_id = moving.client_session_id
            )",
        from.0,
        into
    )
    .execute(&mut **tx)
    .await?;

    sqlx::query!(
        "UPDATE bolt_scores AS moving
            SET user_id = $2
          WHERE moving.user_id = $1
            AND NOT EXISTS (
              SELECT 1 FROM bolt_scores AS held
               WHERE held.user_id = $2
                 AND held.client_score_id = moving.client_score_id
            )",
        from.0,
        into
    )
    .execute(&mut **tx)
    .await?;

    sqlx::query!(
        "INSERT INTO assistant_usage (user_id, usage_date, calls)
         SELECT $2, usage_date, calls FROM assistant_usage WHERE user_id = $1
         ON CONFLICT (user_id, usage_date)
         DO UPDATE SET calls = assistant_usage.calls + EXCLUDED.calls",
        from.0,
        into
    )
    .execute(&mut **tx)
    .await?;

    let deleted = sqlx::query!("DELETE FROM users WHERE id = $1", from.0)
        .execute(&mut **tx)
        .await?
        .rows_affected();

    if deleted == 0 {
        return Err(AccountError::Missing);
    }

    Ok(())
}
