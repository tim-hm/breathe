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
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};

use api::entitlement::{
    SubscriptionTier, Tier, TransactionVerifier, VerificationError, VerifiedTransaction,
};
use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;
use axum::Router;
use chrono::{Duration, Utc};

use crate::harness::{
    GrpcWebResponse, ScriptedModel, TestDatabase, allowance, build_app_with, call_grpc_web_with,
    subscribe,
};

const SUBMIT: &str = "/breathe.v1.EntitlementService/SubmitAppStoreTransaction";
const GET: &str = "/breathe.v1.EntitlementService/GetEntitlement";
const GET_RECOMMENDATION: &str = "/breathe.v1.AssistantService/GetRecommendation";

const USER: &str = "e07171e0-0000-4000-8000-000000000001";
const OTHER_USER: &str = "e07171e0-0000-4000-8000-000000000002";

/// Both products renew monthly, so a fixture's period is a month unless the
/// test is specifically about a longer one.
const MONTH: Duration = Duration::days(30);

/// A verifier that knows a fixed set of tokens and rejects everything else.
///
/// Keyed on the token string so a test can submit "the same JWS" twice and mean
/// it — the idempotency being asserted is about the transaction id inside, and a
/// verifier that minted a fresh id per call would make that untestable. The
/// script itself is never mutated after construction, which is what lets it be
/// shared without a lock.
struct ScriptedVerifier {
    transactions: HashMap<String, VerifiedTransaction>,

    /// How often the seam was reached. The only way to assert that a submission
    /// was refused *before* the token was read, which is the whole content of
    /// the size bound.
    reads: AtomicUsize,
}

impl ScriptedVerifier {
    fn with(tokens: Vec<(&str, VerifiedTransaction)>) -> Arc<Self> {
        Arc::new(Self {
            transactions: tokens
                .into_iter()
                .map(|(token, transaction)| (token.to_owned(), transaction))
                .collect(),
            reads: AtomicUsize::new(0),
        })
    }

    fn reads(&self) -> usize {
        self.reads.load(Ordering::Relaxed)
    }
}

impl TransactionVerifier for ScriptedVerifier {
    fn verify(&self, signed_transaction: &str) -> Result<VerifiedTransaction, VerificationError> {
        self.reads.fetch_add(1, Ordering::Relaxed);

        self.transactions
            .get(signed_transaction)
            .cloned()
            .ok_or_else(|| VerificationError::Untrusted("scripted rejection".to_owned()))
    }
}

/// Signing dates advance a second per fixture built.
///
/// `Utc::now()` for all of them would be correct in principle and flaky in
/// practice: the column stores microseconds, and two fixtures constructed in one
/// expression can land in the same one — at which point the server's `<`
/// correctly refuses the second as not newer, and a test that meant them as a
/// sequence fails perhaps one run in ten. A counter makes "built later" and
/// "signed later" the same fact.
static FIXTURE_SEQUENCE: AtomicI64 = AtomicI64::new(0);

/// One purchase, signed after every fixture built before it.
fn subscription(
    original_transaction_id: &str,
    tier: SubscriptionTier,
    expires_in: Duration,
) -> VerifiedTransaction {
    let sequence = FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);

    VerifiedTransaction {
        original_transaction_id: original_transaction_id.to_owned(),
        tier,
        expires_at: Utc::now() + expires_in,
        signed_at: Utc::now() + Duration::seconds(sequence),
        revoked_at: None,
    }
}

/// The subscription most tests want: a month of Plus.
fn plus(original_transaction_id: &str) -> VerifiedTransaction {
    subscription(original_transaction_id, SubscriptionTier::Plus, MONTH)
}

/// A refund, signed after the purchase it revokes — which is both what Apple
/// sends and what the ordering rule requires to let it through.
fn refund(original_transaction_id: &str) -> VerifiedTransaction {
    VerifiedTransaction {
        revoked_at: Some(Utc::now()),
        ..plus(original_transaction_id)
    }
}

async fn try_submit(
    app: Router,
    user: &str,
    token: &str,
) -> GrpcWebResponse<pb::SubmitAppStoreTransactionResponse> {
    let request = pb::SubmitAppStoreTransactionRequest {
        signed_transaction: token.to_owned(),
    };

    call_grpc_web_with(app, SUBMIT, &request, &[(USER_ID_HEADER, user)]).await
}

async fn submit(app: Router, user: &str, token: &str) -> pb::Entitlement {
    try_submit(app, user, token)
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
    let verifier = ScriptedVerifier::with(vec![("jws-plus", plus("2000000000000001"))]);

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
/// an implementation that extended the period per submission would pass a test
/// that only checked the tier.
#[tokio::test]
async fn resubmitting_the_same_transaction_changes_nothing() {
    let db = TestDatabase::create("entitlement_idempotent").await;
    let verifier = ScriptedVerifier::with(vec![("jws-plus", plus("2000000000000001"))]);

    let first = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let second = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let third = submit(db.app_with_verifier(verifier), USER, "jws-plus").await;

    assert_eq!(first, second);
    assert_eq!(second, third);
    assert_eq!(first.tier, pb::EntitlementTier::Plus as i32);
}

/// The reason the ordering key is `signedDate` and not the expiry.
///
/// Upgrading Plus to Coach mid-month issues a Coach transaction whose expiry is
/// *earlier* than the annual Plus period it replaced. Ordering by expiry — which
/// is what M8 did, before there were two products — keeps the Plus row and
/// leaves somebody paying for Coach and holding Plus. Ordering by `signedDate`
/// takes the whole newer row, shorter expiry and all.
#[tokio::test]
async fn an_upgrade_is_not_shadowed_by_a_longer_cheaper_period() {
    let db = TestDatabase::create("entitlement_upgrade").await;
    // Built in the order they were signed — the counter is what makes that the
    // same statement — so the Coach upgrade is the newer transaction despite
    // carrying the shorter period.
    let long_plus = subscription(
        "2000000000000001",
        SubscriptionTier::Plus,
        Duration::days(365),
    );
    let short_coach = subscription("2000000000000002", SubscriptionTier::Coach, MONTH);

    let verifier = ScriptedVerifier::with(vec![
        ("jws-plus-year", long_plus),
        ("jws-coach-month", short_coach),
    ]);

    let before = submit(
        db.app_with_verifier(verifier.clone()),
        USER,
        "jws-plus-year",
    )
    .await;
    let after = submit(
        db.app_with_verifier(verifier.clone()),
        USER,
        "jws-coach-month",
    )
    .await;

    assert_eq!(after.tier, pb::EntitlementTier::Coach as i32);
    assert!(
        after.expires_at.map(|at| at.seconds) < before.expires_at.map(|at| at.seconds),
        "the upgrade's own shorter period is what the person now holds"
    );

    // And the client resubmitting the superseded Plus transaction on its next
    // launch — which it will, because `currentEntitlements` and
    // `Transaction.updates` have no ordering between them — must not take the
    // upgrade away again.
    let resubmitted = submit(
        db.app_with_verifier(verifier.clone()),
        USER,
        "jws-plus-year",
    )
    .await;
    assert_eq!(resubmitted, after);
    assert_eq!(read(db.app_with_verifier(verifier), USER).await, after);
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
        ("jws-plus", plus("2000000000000001")),
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

/// A refund is final, and the transaction that paid for it is still in the
/// client's hands.
///
/// The revoked transaction and the purchase it revokes are the *same*
/// subscription, and the purchase's payload carries no `revocationDate` — so it
/// verifies perfectly, forever, until its own expiry. What stops it re-granting
/// is that the revocation leaves the ordering marker set to its own `signedDate`
/// rather than clearing it; an earlier submission then loses the comparison it
/// would otherwise win against a null.
///
/// Reachable by an honest client, not only an attacker: `Transaction.updates`
/// and `currentEntitlements` have no ordering between them, so a single launch
/// can hand the server the refund and then the purchase.
///
/// Buying again afterwards has to still work, which is the half a fix could
/// easily break — hence the third submission.
#[tokio::test]
async fn a_refund_cannot_be_undone_by_resubmitting() {
    let db = TestDatabase::create("entitlement_refund_replay").await;
    let verifier = ScriptedVerifier::with(vec![
        ("jws-plus", plus("2000000000000001")),
        ("jws-refunded", refund("2000000000000001")),
        ("jws-bought-again", plus("2000000000000002")),
    ]);

    submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let refunded = submit(db.app_with_verifier(verifier.clone()), USER, "jws-refunded").await;
    assert_eq!(refunded.tier, pb::EntitlementTier::Free as i32);

    let replayed = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    assert_eq!(replayed.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(
        read(db.app_with_verifier(verifier.clone()), USER).await,
        refunded
    );

    let bought_again = submit(
        db.app_with_verifier(verifier.clone()),
        USER,
        "jws-bought-again",
    )
    .await;
    assert_eq!(bought_again.tier, pb::EntitlementTier::Plus as i32);
    assert_eq!(
        read(db.app_with_verifier(verifier), USER).await,
        bought_again
    );
}

/// A `jwsRepresentation` is a string. Somebody can copy it off their own device
/// and submit it from any client under any UUID they mint, and nothing inside
/// the token names who may use it — so the binding has to come from the server.
///
/// This is money rather than principle. Coach's whole content is the language
/// model and its allowance is counted per user per UTC day, so one shared token
/// fanning out across self-minted identities is uncapped provider spend against
/// a per-user ceiling.
#[tokio::test]
async fn a_purchase_entitles_one_identity_at_a_time() {
    let db = TestDatabase::create("entitlement_replay").await;
    let verifier = ScriptedVerifier::with(vec![(
        "jws-coach",
        subscription("2000000000000001", SubscriptionTier::Coach, MONTH),
    )]);

    let bought = submit(db.app_with_verifier(verifier.clone()), USER, "jws-coach").await;

    let replayed = try_submit(
        db.app_with_verifier(verifier.clone()),
        OTHER_USER,
        "jws-coach",
    )
    .await;
    assert_eq!(replayed.status, tonic::Code::PermissionDenied as i32);

    assert_eq!(
        read(db.app_with_verifier(verifier.clone()), OTHER_USER)
            .await
            .tier,
        pb::EntitlementTier::Free as i32
    );
    assert_eq!(
        read(db.app_with_verifier(verifier), USER).await,
        bought,
        "the buyer keeps what they bought"
    );
}

/// The other half of the binding, and the case the original schema comment chose
/// not to bind at all for: there is no account recovery, so somebody who
/// reinstalls and reaches this app with a new identity and the same Apple ID has
/// to be able to take their purchase with them.
///
/// The transaction therefore moves rather than being refused outright — but only
/// once it has sat still for the cooldown, because a binding that moved on demand
/// would be the same fan-out taken in turns, one daily allowance at a time.
/// Backdated in the column, because there is no way to make the clock move.
#[tokio::test]
async fn a_settled_purchase_follows_its_owner_to_a_new_identity() {
    let db = TestDatabase::create("entitlement_transfer").await;
    let verifier = ScriptedVerifier::with(vec![("jws-plus", plus("2000000000000001"))]);

    let bought = submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;

    sqlx::query(
        "UPDATE users SET subscription_claimed_at = now() - interval '2 days' WHERE id = $1",
    )
    .bind(USER.parse::<uuid::Uuid>().expect("a valid uuid"))
    .execute(&db.pool)
    .await
    .expect("the claim is backdated");

    let moved = submit(
        db.app_with_verifier(verifier.clone()),
        OTHER_USER,
        "jws-plus",
    )
    .await;
    assert_eq!(moved.tier, bought.tier);
    assert_eq!(moved.expires_at, bought.expires_at);

    assert_eq!(
        read(db.app_with_verifier(verifier), USER).await.tier,
        pb::EntitlementTier::Free as i32,
        "the transaction moved rather than being shared"
    );
}

/// A real `jwsRepresentation` is a few kilobytes; without a bound the only
/// ceiling is tonic's 4 MiB decode limit, and every byte under it would be
/// split, base64-decoded three times and JSON-parsed on a path with no rate
/// limit in front of it. The verifier's read count is the assertion that
/// matters: rejecting the oversized token *after* doing the work would pass a
/// test that only checked the status.
#[tokio::test]
async fn a_token_too_large_to_be_a_transaction_is_refused_unread() {
    let db = TestDatabase::create("entitlement_oversized").await;
    let verifier = ScriptedVerifier::with(vec![]);

    let oversized = "j".repeat(64 * 1024);
    let response = try_submit(db.app_with_verifier(verifier.clone()), USER, &oversized).await;

    assert_eq!(response.status, tonic::Code::InvalidArgument as i32);
    assert_eq!(verifier.reads(), 0, "nothing decoded it to find out");
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
    let verifier = ScriptedVerifier::with(vec![("jws-plus", plus("2000000000000001"))]);

    submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;

    let other = read(db.app_with_verifier(verifier), OTHER_USER).await;
    assert_eq!(other.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(other.expires_at, None);
}

/// The one thing this server spends money on, and the one gate it therefore
/// enforces. Plus buys the catalogue, which runs on the device; it does not buy
/// a single model call, and neither does free. Asserted through the model's own
/// call count, because every tier gets an answer — only the number of calls
/// behind those answers says who paid for one.
#[tokio::test]
async fn only_coach_reaches_the_model() {
    let db = TestDatabase::create("entitlement_model_access").await;
    assert_eq!(allowance(Tier::Free), 0);
    assert_eq!(allowance(Tier::Plus), 0);
    let coach = allowance(Tier::Coach);
    assert!(coach > 0, "Coach is the tier that buys the model");

    let model = ScriptedModel::always(Ok("box-breathing | Steady.".to_owned()));
    let verifier = ScriptedVerifier::with(vec![
        ("jws-plus", plus("2000000000000001")),
        (
            "jws-coach",
            subscription("2000000000000002", SubscriptionTier::Coach, MONTH),
        ),
    ]);

    // Free, then Plus: the answer arrives either way, and it is the rules.
    let free_answer = recommend(&db, model.clone(), verifier.clone(), USER).await;
    assert_eq!(free_answer.source, pb::AssistantSource::Fallback as i32);

    submit(db.app_with_verifier(verifier.clone()), USER, "jws-plus").await;
    let plus_answer = recommend(&db, model.clone(), verifier.clone(), USER).await;
    assert_eq!(plus_answer.source, pb::AssistantSource::Fallback as i32);
    assert!(!plus_answer.recommendations.is_empty());

    assert_eq!(
        model.calls(),
        0,
        "nothing below Coach may cost a model call, however many times it asks"
    );

    // Coach: the model answers, up to the ceiling, and the call past it does not
    // reach the provider at all.
    submit(db.app_with_verifier(verifier.clone()), USER, "jws-coach").await;
    for _ in 0..coach {
        let answer = recommend(&db, model.clone(), verifier.clone(), USER).await;
        assert_eq!(answer.source, pb::AssistantSource::Model as i32);
    }

    let exhausted = recommend(&db, model.clone(), verifier, USER).await;
    assert_eq!(exhausted.source, pb::AssistantSource::Fallback as i32);
    assert_eq!(model.calls(), coach, "Coach is a ceiling, not its absence");
}

/// The tier is derived on every read rather than stored, so a subscription that
/// ran out answers FREE with nothing having run in between. Written straight
/// into the columns, because there is no way to make Apple's clock move.
#[tokio::test]
async fn an_expiry_in_the_past_reads_as_free() {
    let db = TestDatabase::create("entitlement_lapsed").await;
    let verifier = ScriptedVerifier::with(vec![]);

    // The row is created by the identity layer on the first RPC of any kind, so
    // one call has to happen before there is anything to expire.
    read(db.app_with_verifier(verifier.clone()), USER).await;

    subscribe(&db.pool, USER, "COACH").await;
    sqlx::query("UPDATE users SET subscription_until = now() - interval '1 day' WHERE id = $1")
        .bind(USER.parse::<uuid::Uuid>().expect("a valid uuid"))
        .execute(&db.pool)
        .await
        .expect("the expiry is written");

    let entitlement = read(db.app_with_verifier(verifier), USER).await;
    assert_eq!(entitlement.tier, pb::EntitlementTier::Free as i32);
    assert_eq!(entitlement.expires_at, None);
}
