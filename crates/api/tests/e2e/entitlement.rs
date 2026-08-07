//! `EntitlementService`, over the wire the iOS client uses, against a scripted
//! App Store verifier.
//!
//! No Apple-signed material anywhere. Every transaction here is a bare string
//! the scripted verifier maps to a payload, which is the only way this suite
//! could exist — a real `jwsRepresentation` needs Apple's private key, and one
//! captured from a sandbox purchase would go stale the moment its certificate
//! chain rotated. What the real verifier does with real bytes is pinned by the
//! unit tests beside it; what the *server* does with a verified transaction is
//! pinned here.

use std::collections::HashMap;
use std::sync::Arc;

use api::entitlement::{Tier, TransactionVerifier, VerificationError, VerifiedTransaction};
use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;
use axum::Router;
use chrono::{Duration, Utc};

use crate::harness::{ScriptedModel, TestDatabase, allowance, build_app_with, call_grpc_web_with};

const SUBMIT: &str = "/breathe.v1.EntitlementService/SubmitAppStoreTransaction";
const GET: &str = "/breathe.v1.EntitlementService/GetEntitlement";
const GET_RECOMMENDATION: &str = "/breathe.v1.AssistantService/GetRecommendation";

const USER: &str = "e07171e0-0000-4000-8000-000000000001";
const OTHER_USER: &str = "e07171e0-0000-4000-8000-000000000002";

/// A verifier that knows a fixed set of tokens and rejects everything else.
///
/// Keyed on the token string so a test can submit "the same JWS" twice and mean
/// it — the idempotency being asserted is about the transaction id inside, and a
/// verifier that minted a fresh id per call would make that untestable. Never
/// mutated after construction, which is what lets it be shared without a lock.
struct ScriptedVerifier {
    transactions: HashMap<String, VerifiedTransaction>,
}

impl ScriptedVerifier {
    fn with(tokens: Vec<(&str, VerifiedTransaction)>) -> Arc<Self> {
        Arc::new(Self {
            transactions: tokens
                .into_iter()
                .map(|(token, transaction)| (token.to_owned(), transaction))
                .collect(),
        })
    }
}

impl TransactionVerifier for ScriptedVerifier {
    fn verify(&self, signed_transaction: &str) -> Result<VerifiedTransaction, VerificationError> {
        self.transactions
            .get(signed_transaction)
            .cloned()
            .ok_or_else(|| VerificationError::Untrusted("scripted rejection".to_owned()))
    }
}

fn subscription(original_transaction_id: &str, expires_in: Duration) -> VerifiedTransaction {
    VerifiedTransaction {
        original_transaction_id: original_transaction_id.to_owned(),
        expires_at: Utc::now() + expires_in,
        revoked_at: None,
    }
}

fn refund(original_transaction_id: &str) -> VerifiedTransaction {
    VerifiedTransaction {
        revoked_at: Some(Utc::now()),
        ..subscription(original_transaction_id, Duration::days(365))
    }
}

async fn submit(app: Router, user: &str, token: &str) -> pb::Entitlement {
    let request = pb::SubmitAppStoreTransactionRequest {
        signed_transaction: token.to_owned(),
    };

    call_grpc_web_with::<_, pb::SubmitAppStoreTransactionResponse>(
        app,
        SUBMIT,
        &request,
        &[(USER_ID_HEADER, user)],
    )
    .await
    .into_ok()
    .entitlement
    .expect("every response carries an entitlement")
}

async fn read(app: Router, user: &str) -> pb::Entitlement {
    call_grpc_web_with::<_, pb::GetEntitlementResponse>(
        app,
        GET,
        &pb::GetEntitlementRequest {},
        &[(USER_ID_HEADER, user)],
    )
    .await
    .into_ok()
    .entitlement
    .expect("every response carries an entitlement")
}

async fn recommend(
    db: &TestDatabase,
    model: Arc<ScriptedModel>,
    verifier: Arc<ScriptedVerifier>,
    user: &str,
) -> pb::GetRecommendationResponse {
    call_grpc_web_with::<_, pb::GetRecommendationResponse>(
        build_app_with(db.pool.clone(), model, verifier),
        GET_RECOMMENDATION,
        &pb::GetRecommendationRequest {},
        &[(USER_ID_HEADER, user)],
    )
    .await
    .into_ok()
}

/// The happy path, and the only one that mints an entitlement: a transaction
/// the verifier accepts becomes a tier and an expiry the next call reads back.
/// Asserted through a second RPC rather than the submission's own response,
/// because what matters is that it was *stored*.
#[tokio::test]
async fn a_verified_transaction_becomes_a_readable_entitlement() {
    let db = TestDatabase::create("entitlement_grant").await;
    let verifier = ScriptedVerifier::with(vec![(
        "jws-plus",
        subscription("2000000000000001", Duration::days(365)),
    )]);

    let submitted = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    assert_eq!(submitted.tier, pb::EntitlementTier::Plus as i32);
    assert!(submitted.expires_at.is_some());

    let stored = read(db.app_with_verifier(verifier), USER).await;
    assert_eq!(stored.tier, pb::EntitlementTier::Plus as i32);
    assert_eq!(stored.expires_at, submitted.expires_at);
}

/// Somebody who has never bought anything is FREE with no date, not `NOT_FOUND`
/// and not an error. The client renders a paywall from this, so an error here
/// would make "not subscribed" indistinguishable from "the server is down" —
/// and the app is supposed to work offline.
#[tokio::test]
async fn a_caller_who_has_bought_nothing_is_free() {
    let db = TestDatabase::create("entitlement_default").await;
    let verifier = ScriptedVerifier::with(vec![]);

    let entitlement = read(db.app_with_verifier(verifier), USER).await;

    assert_eq!(entitlement.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(entitlement.expires_at, None);
}

/// The client resubmits on every launch — that is its whole retry strategy — so
/// the same token arriving repeatedly has to be one entitlement rather than an
/// error or a second grant. The expiry not moving is the assertion that matters:
/// a naive implementation that added a year per submission would pass a test
/// that only checked the tier.
#[tokio::test]
async fn resubmitting_the_same_transaction_changes_nothing() {
    let db = TestDatabase::create("entitlement_idempotent").await;
    let verifier = ScriptedVerifier::with(vec![(
        "jws-plus",
        subscription("2000000000000001", Duration::days(365)),
    )]);

    let first = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let second = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let third = submit(db.app_with_verifier(verifier), USER, "jws-plus").await;

    assert_eq!(first, second);
    assert_eq!(second, third);
    assert_eq!(first.tier, pb::EntitlementTier::Plus as i32);
}

/// `Transaction.updates` and `currentEntitlements` have no ordering between
/// them, so a client can hand the server last year's transaction after this
/// year's renewal. The older one must not shorten the subscription — this is
/// what `GREATEST` in the repository is for, and an assignment would fail here.
#[tokio::test]
async fn an_older_transaction_cannot_shorten_a_renewed_subscription() {
    let db = TestDatabase::create("entitlement_out_of_order").await;
    let verifier = ScriptedVerifier::with(vec![
        (
            "jws-renewal",
            subscription("2000000000000001", Duration::days(365)),
        ),
        (
            "jws-original",
            subscription("2000000000000001", Duration::days(1)),
        ),
    ]);

    let renewed = submit(db.app_with_verifier(verifier.clone()), USER, "jws-renewal").await;
    let after_the_old_one = submit(db.app_with_verifier(verifier), USER, "jws-original").await;

    assert_eq!(after_the_old_one, renewed);
}

/// A refund revokes — and only the subscription it paid for. The transaction
/// still verifies and its expiry is still in the future; what ends the
/// entitlement is the revocation date, and nothing else in the payload says so.
///
/// The unrelated refund is the half that could not be seen from the other:
/// somebody who let one subscription lapse, bought another, and then had the old
/// one refunded must keep what they are still paying for.
#[tokio::test]
async fn a_refund_ends_only_the_subscription_it_paid_for() {
    let db = TestDatabase::create("entitlement_revoked").await;
    let verifier = ScriptedVerifier::with(vec![
        (
            "jws-plus",
            subscription("2000000000000001", Duration::days(365)),
        ),
        ("jws-refunded", refund("2000000000000001")),
        ("jws-other-refund", refund("2000000000000009")),
    ]);

    let bought = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;

    let unrelated = submit(
        db.app_with_verifier(verifier.clone()),
        USER,
        "jws-other-refund",
    )
    .await;
    assert_eq!(unrelated, bought);

    let after_refund = submit(db.app_with_verifier(verifier.clone()), USER, "jws-refunded").await;
    assert_eq!(after_refund.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(after_refund.expires_at, None);
    assert_eq!(
        read(db.app_with_verifier(verifier), USER).await,
        after_refund
    );
}

/// A token the verifier refuses buys nothing and says so as `INVALID_ARGUMENT`,
/// not as a quietly free entitlement. The distinction is what lets the client
/// tell a broken submission apart from a lapsed subscription.
#[tokio::test]
async fn an_unverifiable_transaction_is_refused() {
    let db = TestDatabase::create("entitlement_forged").await;
    let verifier = ScriptedVerifier::with(vec![]);

    let response = call_grpc_web_with::<_, pb::SubmitAppStoreTransactionResponse>(
        db.app_with_verifier(verifier.clone()),
        SUBMIT,
        &pb::SubmitAppStoreTransactionRequest {
            signed_transaction: "forged".to_owned(),
        },
        &[(USER_ID_HEADER, USER)],
    )
    .await;

    assert_eq!(response.status, tonic::Code::InvalidArgument as i32);
    assert_eq!(
        read(db.app_with_verifier(verifier), USER).await.tier,
        pb::EntitlementTier::Free as i32
    );
}

/// An entitlement is one person's. The purchase is stored against the caller in
/// the header, so somebody else reading with their own identity sees nothing —
/// the same containment `ProfileService` and `JourneyService` rely on, pinned
/// separately here because this is the one it costs money to get wrong.
#[tokio::test]
async fn one_persons_purchase_does_not_entitle_another() {
    let db = TestDatabase::create("entitlement_isolation").await;
    let verifier = ScriptedVerifier::with(vec![(
        "jws-plus",
        subscription("2000000000000001", Duration::days(365)),
    )]);

    submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;

    let other = read(db.app_with_verifier(verifier), OTHER_USER).await;
    assert_eq!(other.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(other.expires_at, None);
}

/// What the subscription actually buys. Free runs out and falls back; the same
/// person, after a verified purchase, keeps going well past that ceiling.
/// Asserted through the model's call count, because both tiers answer — only the
/// number of calls behind the answers says which ceiling bound.
#[tokio::test]
async fn plus_raises_the_daily_model_allowance() {
    let db = TestDatabase::create("entitlement_quota").await;
    let free = allowance(Tier::Free);
    let plus = allowance(Tier::Plus);
    assert!(
        plus > free,
        "the tiers must differ or there is nothing to buy"
    );

    let model = ScriptedModel::always(Ok("box-breathing | Steady.".to_owned()));
    let verifier = ScriptedVerifier::with(vec![(
        "jws-plus",
        subscription("2000000000000001", Duration::days(365)),
    )]);

    // Free: the ceiling binds, and the call past it never reaches the model.
    for _ in 0..=free {
        recommend(&db, model.clone(), verifier.clone(), USER).await;
    }
    assert_eq!(model.calls(), free);

    // The same person, now a subscriber, spends the rest of the larger
    // allowance — including the call the free ceiling had just refused.
    submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    for _ in free..plus {
        recommend(&db, model.clone(), verifier.clone(), USER).await;
    }
    assert_eq!(model.calls(), plus);

    // And Plus is a bigger ceiling, not the absence of one.
    recommend(&db, model.clone(), verifier, USER).await;
    assert_eq!(model.calls(), plus);
}

/// The tier is derived on every read rather than stored, so a subscription that
/// ran out answers FREE with nothing having run in between. Written straight
/// into the column, because there is no way to make Apple's clock move.
#[tokio::test]
async fn an_expiry_in_the_past_reads_as_free() {
    let db = TestDatabase::create("entitlement_lapsed").await;
    let verifier = ScriptedVerifier::with(vec![]);

    // The row is created by the identity layer on the first RPC of any kind, so
    // one call has to happen before there is anything to expire.
    read(db.app_with_verifier(verifier.clone()), USER).await;

    sqlx::query("UPDATE users SET plus_until = now() - interval '1 day' WHERE id = $1")
        .bind(USER.parse::<uuid::Uuid>().expect("a valid uuid"))
        .execute(&db.pool)
        .await
        .expect("the expiry is written");

    let entitlement = read(db.app_with_verifier(verifier), USER).await;
    assert_eq!(entitlement.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(entitlement.expires_at, None);
}
