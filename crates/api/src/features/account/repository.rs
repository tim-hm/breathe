//! Account SQL — one column on `users`, the merge a returning sign-in performs,
//! and the erasure a departure does.
//!
//! The row's existence is `crate::identity`'s business, which is why nothing
//! here inserts a user. What it does do that no other repository does is *delete*
//! one — which is why the merge runs inside a single transaction, and why the
//! erasure below explains at length why it needs neither transaction nor lock.

use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::errors::AccountError;
use crate::identity::UserId;

/// Erases a user row, and with it everything the schema hangs off that row.
///
/// One statement, because the schema already says what erasure means. `sessions`
/// and `bolt_scores` (`0005_journey.sql`) and `assistant_usage`
/// (`0006_assistant_quota.sql`) are all `ON DELETE CASCADE`, the profile answers
/// are columns on `users` itself (`0004_users_and_profiles.sql`), and the App
/// Store binding is two more columns — so it is released here exactly as [`merge`]
/// releases the identity it folds away, leaving the transaction free to entitle
/// whoever presents it next.
///
/// No transaction and no lock, which is where this parts company with [`merge`].
/// The lock there exists to stop a concurrent write being cascaded away *while
/// the row survives* — half a merge is a person whose sessions moved and whose
/// scores did not. Nothing survives here, so every outcome of that race is the
/// one the caller asked for: a sync holding `FOR KEY SHARE` on the row makes
/// this `DELETE` wait, and whatever it committed goes with the cascade.
///
/// What this cannot defend against is the request *after* it. `identity::resolve`
/// upserts a row for any well-formed id, so a client that goes on sending the
/// erased one recreates it empty — which is why `DeleteAccount` requires the
/// device to mint a fresh identity before it sends anything else, and why the
/// e2e suite pins that behaviour rather than leaving it as a remark.
///
/// `rows_affected` is not checked. The middleware has just created the row if it
/// were missing, so the only way to affect none is a second deletion of the same
/// identity, and "it is gone" is the honest answer to that.
pub async fn delete_account(pool: &PgPool, caller: UserId) -> Result<(), AccountError> {
    sqlx::query!("DELETE FROM users WHERE id = $1", caller.0)
        .execute(pool)
        .await?;

    Ok(())
}

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
///   caller's is folded into it by [`merge`] and the device adopts its id —
///   unless the caller is itself bound to some third Apple account, which is
///   refused.
///
/// The refusal in the last two cases is one rule, not two: an identity already
/// bound to an Apple account is never rebound, and both [`claim`] and [`merge`]
/// answer `AlreadyBound`. Which of them a caller reaches depends only on whether
/// anybody happens to hold the account being signed in to — invisible from the
/// device, and no basis for the difference between an error and a deletion.
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
/// `from` must be anonymous, and the lock below is where that is checked. A row
/// carrying an `apple_user_id` of its own belongs to somebody who proved a
/// *different* Apple account, and folding it away would destroy the only record
/// that that account has a history — so it is refused as `AlreadyBound`, the same
/// answer [`claim`] gives the same person arriving by the other branch.
/// Possession of an anonymous id is the whole of the claim to it (`identity.rs`
/// says so), and that is not a credential this may weigh against a signed-in one.
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
///
/// ## Why `from` is locked first
///
/// The lock is not tidiness, and its position above the reparents is the whole of
/// what it does. A sync landing on `from` at the same moment — the same device,
/// which has not been told its id is about to change — inserts a child row, and
/// that insert takes `FOR KEY SHARE` on `from`'s `users` row for the life of its
/// transaction. Nothing in the reparents conflicts with that lock, so without the
/// `FOR UPDATE` below the sequence is: the reparent runs against a snapshot taken
/// before the insert committed and does not see it, the insert commits, and the
/// `DELETE` then destroys it through `ON DELETE CASCADE`. Silent, and precisely
/// the history this function exists to preserve.
///
/// `FOR UPDATE` conflicts with `FOR KEY SHARE`, so taking it here makes the merge
/// wait for an in-flight write instead of stepping over it — and because each
/// statement takes its own snapshot under READ COMMITTED, the reparents that
/// follow the lock see everything it waited for. A write that starts *after* the
/// lock is held blocks, and then fails its foreign key once `from` is gone rather
/// than being cascaded away; the client resends under the id it has by then
/// adopted, which is the outcome that loses nothing.
///
/// It doubles as the existence check the `DELETE` would otherwise need — no row to
/// lock is a caller whose identity vanished between the middleware creating it and
/// this write — and it reads the binding the anonymity check turns on, so proving
/// `from` anonymous costs no statement of its own.
async fn merge(
    tx: &mut Transaction<'_, Postgres>,
    from: UserId,
    into: Uuid,
) -> Result<(), AccountError> {
    let bound_to = sqlx::query_scalar!(
        "SELECT apple_user_id FROM users WHERE id = $1 FOR UPDATE",
        from.0
    )
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(AccountError::Missing)?;

    // `into` holds the Apple account being signed in to and is a different row,
    // so `users.apple_user_id` being `UNIQUE` makes any binding here another one.
    if bound_to.is_some() {
        return Err(AccountError::AlreadyBound);
    }

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

    sqlx::query!("DELETE FROM users WHERE id = $1", from.0)
        .execute(&mut **tx)
        .await?;

    Ok(())
}
