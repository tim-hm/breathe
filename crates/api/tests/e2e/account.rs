//! `AccountService`, over the wire the iOS client uses, against a scripted
//! Sign in with Apple verifier.
//!
//! Nothing Apple signed anywhere, and nothing that could go looking for it:
//! every token here is a bare string the scripted verifier maps to an Apple
//! account. A real identity token needs Apple's private key, and checking one
//! needs a key fetched from Apple over the network — so this is the only shape
//! the suite could have. What the real verifier does with real bytes is pinned by
//! the unit tests beside it; what the *server* does with a proven Apple account
//! is pinned here.

use api::identity::USER_ID_HEADER;
use api::proto::ond::v1 as pb;
use axum::Router;
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

use crate::harness::{
    GrpcWebResponse, ScriptedIdentityVerifier, TestDatabase, call_grpc_web_with, subscribe,
};

const SIGN_IN: &str = "/ond.v1.AccountService/SignInWithApple";

/// The identity a person already had — the one a returning sign-in hands back.
const OLD_DEVICE: &str = "acc00000-0000-4000-8000-000000000001";

/// The identity a new device minted on first launch, before signing in.
const NEW_DEVICE: &str = "acc00000-0000-4000-8000-000000000002";

/// Apple's `sub`, in the shape Apple actually issues one.
const APPLE_ACCOUNT: &str = "001234.abcdef0123456789abcdef0123456789.0123";
const OTHER_APPLE_ACCOUNT: &str = "009876.fedcba9876543210fedcba9876543210.9876";

fn uuid(value: &str) -> Uuid {
    value.parse().expect("a valid uuid")
}

async fn try_sign_in(
    app: Router,
    caller: &str,
    token: &str,
) -> GrpcWebResponse<pb::SignInWithAppleResponse> {
    let request = pb::SignInWithAppleRequest {
        identity_token: token.to_owned(),
    };

    call_grpc_web_with(app, SIGN_IN, &request, &[(USER_ID_HEADER, caller)]).await
}

/// The id the device should carry from now on.
async fn sign_in(app: Router, caller: &str, token: &str) -> String {
    try_sign_in(app, caller, token).await.into_ok().user_id
}

/// A user row, as the identity layer would have created it on the device's first
/// RPC.
///
/// Written directly rather than by making a call, so a test can lay out both
/// sides of a merge before either of them signs in.
async fn given_user(pool: &PgPool, user: &str, display_name: &str) {
    sqlx::query!(
        "INSERT INTO users (id, display_name) VALUES ($1, $2)
         ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name",
        uuid(user),
        display_name
    )
    .execute(pool)
    .await
    .expect("the user row is written");
}

/// One breathed session. `slug` is what tells two rows sharing a
/// `client_session_id` apart, which is the only way to see which copy a merge
/// kept.
async fn given_session(pool: &PgPool, user: &str, client_session_id: &str, slug: &str) {
    sqlx::query!(
        "INSERT INTO sessions (
            user_id, client_session_id, technique_slug, started_at,
            duration_ms, cycles_completed, breath_count, completed
         ) VALUES ($1, $2, $3, now(), 60000, 5, 20, true)",
        uuid(user),
        uuid(client_session_id),
        slug
    )
    .execute(pool)
    .await
    .expect("the session is written");
}

/// One controlled pause. `seconds` plays the part `slug` does for a session.
async fn given_bolt_score(pool: &PgPool, user: &str, client_score_id: &str, seconds: i32) {
    sqlx::query!(
        "INSERT INTO bolt_scores (user_id, client_score_id, seconds) VALUES ($1, $2, $3)",
        uuid(user),
        uuid(client_score_id),
        seconds
    )
    .execute(pool)
    .await
    .expect("the score is written");
}

/// A day's worth of spent allowance, `days_ago` before today's UTC date.
async fn given_quota(pool: &PgPool, user: &str, days_ago: i32, calls: i32) {
    sqlx::query!(
        "INSERT INTO assistant_usage (user_id, usage_date, calls)
         VALUES ($1, CURRENT_DATE - $2::integer, $3)",
        uuid(user),
        days_ago,
        calls
    )
    .execute(pool)
    .await
    .expect("the quota row is written");
}

/// Every session on one identity, as `(client_session_id, technique_slug)`.
async fn sessions_of(pool: &PgPool, user: &str) -> Vec<(Uuid, String)> {
    sqlx::query!(
        "SELECT client_session_id, technique_slug FROM sessions
          WHERE user_id = $1 ORDER BY technique_slug",
        uuid(user)
    )
    .fetch_all(pool)
    .await
    .expect("the sessions are readable")
    .into_iter()
    .map(|row| (row.client_session_id, row.technique_slug))
    .collect()
}

async fn bolt_seconds_of(pool: &PgPool, user: &str) -> Vec<i32> {
    sqlx::query_scalar!(
        "SELECT seconds FROM bolt_scores WHERE user_id = $1 ORDER BY seconds",
        uuid(user)
    )
    .fetch_all(pool)
    .await
    .expect("the scores are readable")
}

async fn quota_of(pool: &PgPool, user: &str) -> Vec<(NaiveDate, i32)> {
    sqlx::query!(
        "SELECT usage_date, calls FROM assistant_usage WHERE user_id = $1 ORDER BY usage_date",
        uuid(user)
    )
    .fetch_all(pool)
    .await
    .expect("the quota is readable")
    .into_iter()
    .map(|row| (row.usage_date, row.calls))
    .collect()
}

async fn exists(pool: &PgPool, user: &str) -> bool {
    sqlx::query_scalar!("SELECT count(*) FROM users WHERE id = $1", uuid(user))
        .fetch_one(pool)
        .await
        .expect("the count is readable")
        .unwrap_or_default()
        > 0
}

async fn apple_account_of(pool: &PgPool, user: &str) -> Option<String> {
    sqlx::query_scalar!("SELECT apple_user_id FROM users WHERE id = $1", uuid(user))
        .fetch_one(pool)
        .await
        .expect("the row is readable")
}

/// The first sign-in on an Apple account nobody holds: the binding lands on the
/// caller's own row and the caller keeps its id, so nothing on the device has to
/// change.
///
/// Signing in again is asserted alongside it because the client will: there is no
/// server session to expire, so a launch that finds a credential in the Keychain
/// re-presents it, and that must be the same identity rather than an error.
#[tokio::test]
async fn a_first_sign_in_binds_the_caller_and_keeps_its_id() {
    let db = TestDatabase::create("account_first").await;
    let verifier = ScriptedIdentityVerifier::with(vec![("jws-apple", APPLE_ACCOUNT)]);

    let adopted = sign_in(
        db.app_with_identity(verifier.clone()),
        NEW_DEVICE,
        "jws-apple",
    )
    .await;
    assert_eq!(adopted, NEW_DEVICE);
    assert_eq!(
        apple_account_of(&db.pool, NEW_DEVICE).await.as_deref(),
        Some(APPLE_ACCOUNT),
        "the binding is what makes the identity findable from another device"
    );

    let again = sign_in(db.app_with_identity(verifier), NEW_DEVICE, "jws-apple").await;
    assert_eq!(again, adopted);
}

/// The whole point of the feature: a new phone mints an identity of its own,
/// signs in, and is handed back the one this Apple account already had.
///
/// The device's own row is gone afterwards rather than left orphaned — a row
/// nothing can reach again is a row nothing will ever delete.
#[tokio::test]
async fn a_returning_sign_in_hands_back_the_identity_the_account_already_had() {
    let db = TestDatabase::create("account_returning").await;
    let verifier = ScriptedIdentityVerifier::with(vec![("jws-apple", APPLE_ACCOUNT)]);

    sign_in(
        db.app_with_identity(verifier.clone()),
        OLD_DEVICE,
        "jws-apple",
    )
    .await;

    let adopted = sign_in(db.app_with_identity(verifier), NEW_DEVICE, "jws-apple").await;

    assert_eq!(adopted, OLD_DEVICE);
    assert!(!exists(&db.pool, NEW_DEVICE).await);
}

/// The merge, with history on both sides and a collision in the middle of it.
///
/// Three rules in one test because they are one transaction: a session and a
/// score held by only one side survive on the older identity; a
/// client-generated id held by *both* is one record that reached the server
/// twice, so the older identity's copy stays and the newcomer's is dropped; and a
/// day's assistant allowance spent on both is summed rather than replaced —
/// keeping the older count would let signing in launder whatever the new device
/// had already spent.
#[tokio::test]
async fn a_merge_keeps_both_histories_and_sums_a_shared_days_allowance() {
    let db = TestDatabase::create("account_merge").await;
    let verifier = ScriptedIdentityVerifier::with(vec![("jws-apple", APPLE_ACCOUNT)]);

    let shared_session = "5e551011-0000-4000-8000-000000000001";
    let shared_score = "b01f0000-0000-4000-8000-000000000001";

    given_user(&db.pool, OLD_DEVICE, "Older").await;
    given_session(&db.pool, OLD_DEVICE, shared_session, "kept-on-collision").await;
    given_session(
        &db.pool,
        OLD_DEVICE,
        "5e551011-0000-4000-8000-000000000002",
        "only-on-the-old-device",
    )
    .await;
    given_bolt_score(&db.pool, OLD_DEVICE, shared_score, 30).await;
    given_bolt_score(
        &db.pool,
        OLD_DEVICE,
        "b01f0000-0000-4000-8000-000000000002",
        41,
    )
    .await;
    given_quota(&db.pool, OLD_DEVICE, 0, 3).await;

    given_user(&db.pool, NEW_DEVICE, "Newer").await;
    given_session(&db.pool, NEW_DEVICE, shared_session, "dropped-on-collision").await;
    given_session(
        &db.pool,
        NEW_DEVICE,
        "5e551011-0000-4000-8000-000000000003",
        "only-on-the-new-device",
    )
    .await;
    // The same score resent, at a value the assertion below could not confuse
    // with the one the old device holds.
    given_bolt_score(&db.pool, NEW_DEVICE, shared_score, 55).await;
    given_bolt_score(
        &db.pool,
        NEW_DEVICE,
        "b01f0000-0000-4000-8000-000000000003",
        22,
    )
    .await;
    given_quota(&db.pool, NEW_DEVICE, 0, 2).await;
    given_quota(&db.pool, NEW_DEVICE, 1, 7).await;

    sign_in(
        db.app_with_identity(verifier.clone()),
        OLD_DEVICE,
        "jws-apple",
    )
    .await;
    let adopted = sign_in(db.app_with_identity(verifier), NEW_DEVICE, "jws-apple").await;
    assert_eq!(adopted, OLD_DEVICE);

    assert_eq!(
        sessions_of(&db.pool, OLD_DEVICE).await,
        vec![
            (uuid(shared_session), "kept-on-collision".to_owned()),
            (
                uuid("5e551011-0000-4000-8000-000000000003"),
                "only-on-the-new-device".to_owned()
            ),
            (
                uuid("5e551011-0000-4000-8000-000000000002"),
                "only-on-the-old-device".to_owned()
            ),
        ],
        "one session from each side, and one row for the id both sides held"
    );

    assert_eq!(
        bolt_seconds_of(&db.pool, OLD_DEVICE).await,
        vec![22, 30, 41],
        "55 was the newcomer's copy of a score the old device already had"
    );

    let today = quota_of(&db.pool, OLD_DEVICE).await;
    assert_eq!(today.len(), 2, "{today:?}");
    assert_eq!(today[0].1, 7, "yesterday's spend came across untouched");
    assert_eq!(today[1].1, 5, "today is 3 + 2, not 3 and not 2");

    assert!(!exists(&db.pool, NEW_DEVICE).await);
    assert_eq!(
        sqlx::query_scalar!(
            "SELECT display_name FROM users WHERE id = $1",
            uuid(OLD_DEVICE)
        )
        .fetch_one(&db.pool)
        .await
        .expect("the row is readable"),
        Some("Older".to_owned()),
        "the surviving row keeps its own profile answers"
    );
}

/// A subscription does not ride the merge across, and does not need to.
///
/// Deleting the newcomer releases its `app_store_original_transaction_id`
/// outright, and the client resubmits its `StoreKit` transaction on every launch —
/// so the entitlement re-lands on the surviving identity against no holder at
/// all. Copying it here would mean reasoning about the unique constraint and the
/// transfer cooldown for an outcome the next launch produces by itself.
#[tokio::test]
async fn a_merge_does_not_carry_an_entitlement_across() {
    let db = TestDatabase::create("account_entitlement").await;
    let verifier = ScriptedIdentityVerifier::with(vec![("jws-apple", APPLE_ACCOUNT)]);

    given_user(&db.pool, OLD_DEVICE, "Older").await;
    subscribe(&db.pool, NEW_DEVICE, "COACH").await;

    sign_in(
        db.app_with_identity(verifier.clone()),
        OLD_DEVICE,
        "jws-apple",
    )
    .await;
    sign_in(db.app_with_identity(verifier), NEW_DEVICE, "jws-apple").await;

    let tier = sqlx::query_scalar!(
        r#"SELECT subscription_tier::text FROM users WHERE id = $1"#,
        uuid(OLD_DEVICE)
    )
    .fetch_one(&db.pool)
    .await
    .expect("the row is readable");

    assert_eq!(
        tier, None,
        "the surviving row was not handed a subscription"
    );
}

/// A token the verifier refuses binds nothing, and says so as `UNAUTHENTICATED`
/// rather than as a quietly successful sign-in. The identity a client would
/// persist off a successful response is the whole of its future access, so
/// "rejected" and "you are now this person" must never be confusable.
#[tokio::test]
async fn an_unverifiable_token_binds_nothing() {
    let db = TestDatabase::create("account_forged").await;
    let verifier = ScriptedIdentityVerifier::refusing();

    let response = try_sign_in(db.app_with_identity(verifier), NEW_DEVICE, "forged").await;

    assert_eq!(response.status, tonic::Code::Unauthenticated as i32);
    assert_eq!(apple_account_of(&db.pool, NEW_DEVICE).await, None);
}

/// An installation already signed in to one Apple account is refused a second,
/// rather than silently rebound.
///
/// Rebinding would drop the first account's only route back to its history —
/// `apple_user_id` is the sole record of it — and the person doing this is
/// reachable only by a client that skipped signing out, so the refusal is the
/// answer that loses nothing.
#[tokio::test]
async fn an_installation_bound_to_one_apple_account_is_refused_a_second() {
    let db = TestDatabase::create("account_rebind").await;
    let verifier = ScriptedIdentityVerifier::with(vec![
        ("jws-apple", APPLE_ACCOUNT),
        ("jws-other", OTHER_APPLE_ACCOUNT),
    ]);

    sign_in(
        db.app_with_identity(verifier.clone()),
        NEW_DEVICE,
        "jws-apple",
    )
    .await;

    let response = try_sign_in(db.app_with_identity(verifier), NEW_DEVICE, "jws-other").await;

    assert_eq!(response.status, tonic::Code::FailedPrecondition as i32);
    assert_eq!(
        apple_account_of(&db.pool, NEW_DEVICE).await.as_deref(),
        Some(APPLE_ACCOUNT),
        "the first account keeps the row it is the only record of"
    );
}
