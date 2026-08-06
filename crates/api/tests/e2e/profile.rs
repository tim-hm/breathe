//! `ProfileService` and the identity layer under it, over the wire the iOS
//! client uses.

use api::identity::USER_ID_HEADER;
use api::proto::breathe::v1 as pb;

use crate::harness::{GrpcWebResponse, TestDatabase, call_grpc_web, call_grpc_web_with};

const GET_PROFILE: &str = "/breathe.v1.ProfileService/GetProfile";
const UPDATE_PROFILE: &str = "/breathe.v1.ProfileService/UpdateProfile";
const LIST_TECHNIQUES: &str = "/breathe.v1.TechniqueService/ListTechniques";

/// A stable, valid identity. Fixed rather than random so a failing test leaves a
/// row someone can go and look at.
const USER: &str = "3f2b1c4d-0000-4000-8000-000000000001";

/// The round trip the onboarding screen performs: answers in, the same answers
/// back out on the next launch. Every field is set to something other than its
/// proto zero value, because a server that dropped the write entirely would
/// return a profile of zeros that reads as plausible.
#[tokio::test]
async fn onboarding_answers_survive_a_second_call() {
    let db = TestDatabase::create("profile_round_trip").await;

    let submitted = pb::Profile {
        goals: vec![
            pb::TechniqueGoal::Focus as i32,
            pb::TechniqueGoal::Sleep as i32,
        ],
        experience_level: pb::ExperienceLevel::Occasional as i32,
        reminder_intensity: pb::ReminderIntensity::Gentle as i32,
        intent_note: "  I want to stop clenching my jaw  ".to_owned(),
    };

    let updated = update(&db, USER, Some(submitted)).await.into_ok();
    let stored = updated.profile.expect("the update echoes what it stored");

    // The order the person picked, not the order the enum declares.
    assert_eq!(
        stored.goals,
        vec![
            pb::TechniqueGoal::Focus as i32,
            pb::TechniqueGoal::Sleep as i32
        ]
    );
    assert_eq!(stored.intent_note, "I want to stop clenching my jaw");

    let fetched = get(&db, USER).await.into_ok();
    assert_eq!(fetched.profile, Some(stored));
}

/// The default has to survive the whole path — an empty message in, silence out.
/// This is the one assertion that would catch a renumbered `ReminderIntensity`,
/// where a client that answered "never" would start receiving reminders.
#[tokio::test]
async fn an_unanswered_profile_reads_back_as_never() {
    let db = TestDatabase::create("profile_defaults").await;

    let profile = get(&db, USER).await.into_ok().profile.expect("a profile");

    assert_eq!(
        profile.reminder_intensity,
        pb::ReminderIntensity::Never as i32
    );
    assert_eq!(
        profile.experience_level,
        pb::ExperienceLevel::Unspecified as i32,
        "nobody has been asked yet, which is not the same as answering `new`"
    );
    assert!(profile.goals.is_empty());
    assert!(profile.intent_note.is_empty());
}

/// The lazy upsert, from both sides: the first RPC of any kind creates the row,
/// and every later one finds it rather than replacing it. A `DO UPDATE` upsert
/// would pass the first assertion and wipe the profile in the second.
#[tokio::test]
async fn the_first_rpc_creates_the_row_and_later_ones_reuse_it() {
    let db = TestDatabase::create("profile_lazy_upsert").await;

    assert_eq!(count_users(&db).await, 0, "the seed creates no users");

    // Deliberately the *public* catalogue call: identity is resolved for every
    // service, so a person who onboards offline still has a row waiting.
    let listed: pb::ListTechniquesResponse = call_grpc_web_with(
        db.app(),
        LIST_TECHNIQUES,
        &pb::ListTechniquesRequest {},
        &[(USER_ID_HEADER, USER)],
    )
    .await
    .into_ok();

    assert!(!listed.techniques.is_empty());
    assert_eq!(count_users(&db).await, 1);

    update(
        &db,
        USER,
        Some(pb::Profile {
            goals: vec![pb::TechniqueGoal::Calm as i32],
            experience_level: pb::ExperienceLevel::New as i32,
            reminder_intensity: pb::ReminderIntensity::Daily as i32,
            intent_note: String::new(),
        }),
    )
    .await
    .into_ok();

    let refetched = get(&db, USER).await.into_ok();

    assert_eq!(count_users(&db).await, 1, "the second call reused the row");
    assert_eq!(
        refetched.profile.expect("a profile").reminder_intensity,
        pb::ReminderIntensity::Daily as i32,
        "a later RPC must not reset the answers the identity row was created with"
    );
}

/// Both halves of "profile RPCs require the header": absent is a call with no
/// claim, malformed is a claim that does not parse. Neither may be quietly
/// treated as anonymity, because both would otherwise read someone else's
/// profile or none at all.
#[tokio::test]
async fn a_profile_call_without_a_usable_identity_is_unauthenticated() {
    let db = TestDatabase::create("profile_unauthenticated").await;

    let missing: GrpcWebResponse<pb::GetProfileResponse> =
        call_grpc_web(db.app(), GET_PROFILE, &pb::GetProfileRequest {}).await;
    assert_eq!(missing.status, tonic::Code::Unauthenticated as i32);
    assert!(missing.message.is_none());

    let malformed: GrpcWebResponse<pb::GetProfileResponse> = call_grpc_web_with(
        db.app(),
        GET_PROFILE,
        &pb::GetProfileRequest {},
        &[(USER_ID_HEADER, "not-a-uuid")],
    )
    .await;
    assert_eq!(malformed.status, tonic::Code::Unauthenticated as i32);

    assert_eq!(count_users(&db).await, 0, "neither call created a row");
}

/// The catalogue is public reference data and must stay readable with no
/// identity at all — the app's first screen renders before the Keychain has
/// been written. A malformed header is still refused there, because a client
/// that sends one is claiming an identity and getting it wrong.
#[tokio::test]
async fn the_catalogue_stays_public() {
    let db = TestDatabase::create("profile_public_catalogue").await;

    let anonymous: pb::ListTechniquesResponse =
        call_grpc_web(db.app(), LIST_TECHNIQUES, &pb::ListTechniquesRequest {})
            .await
            .into_ok();
    assert!(!anonymous.techniques.is_empty());

    let malformed: GrpcWebResponse<pb::ListTechniquesResponse> = call_grpc_web_with(
        db.app(),
        LIST_TECHNIQUES,
        &pb::ListTechniquesRequest {},
        &[(USER_ID_HEADER, "3f2b1c4d")],
    )
    .await;
    assert_eq!(malformed.status, tonic::Code::Unauthenticated as i32);
}

/// One person's answers must never reach another's `GetProfile`. There is no id
/// in the request message, so the only way this can break is the layer reading
/// the wrong header or the service ignoring the extension.
#[tokio::test]
async fn profiles_are_scoped_to_the_calling_identity() {
    let db = TestDatabase::create("profile_scoping").await;
    let other = "3f2b1c4d-0000-4000-8000-000000000002";

    update(
        &db,
        USER,
        Some(pb::Profile {
            goals: vec![pb::TechniqueGoal::Energy as i32],
            experience_level: pb::ExperienceLevel::Regular as i32,
            reminder_intensity: pb::ReminderIntensity::Daily as i32,
            intent_note: "mine".to_owned(),
        }),
    )
    .await
    .into_ok();

    let theirs = get(&db, other).await.into_ok().profile.expect("a profile");

    assert!(theirs.goals.is_empty());
    assert!(theirs.intent_note.is_empty());
    assert_eq!(
        theirs.reminder_intensity,
        pb::ReminderIntensity::Never as i32
    );
}

/// A goal the server cannot represent fails the call rather than being dropped
/// from the set, and the message says which field — an `INVALID_ARGUMENT` the
/// caller can act on, unlike the opaque `internal` a constraint violation would
/// have produced.
#[tokio::test]
async fn an_unrepresentable_answer_is_rejected_with_its_reason() {
    let db = TestDatabase::create("profile_invalid_answer").await;

    let response = update(
        &db,
        USER,
        Some(pb::Profile {
            goals: vec![pb::TechniqueGoal::Unspecified as i32],
            experience_level: pb::ExperienceLevel::Unspecified as i32,
            reminder_intensity: pb::ReminderIntensity::Never as i32,
            intent_note: String::new(),
        }),
    )
    .await;

    assert_eq!(response.status, tonic::Code::InvalidArgument as i32);
    assert!(response.status_message.contains("goal"));

    let missing_message = update(&db, USER, None).await;
    assert_eq!(missing_message.status, tonic::Code::InvalidArgument as i32);
}

async fn get(db: &TestDatabase, user: &str) -> GrpcWebResponse<pb::GetProfileResponse> {
    call_grpc_web_with(
        db.app(),
        GET_PROFILE,
        &pb::GetProfileRequest {},
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn update(
    db: &TestDatabase,
    user: &str,
    profile: Option<pb::Profile>,
) -> GrpcWebResponse<pb::UpdateProfileResponse> {
    call_grpc_web_with(
        db.app(),
        UPDATE_PROFILE,
        &pb::UpdateProfileRequest { profile },
        &[(USER_ID_HEADER, user)],
    )
    .await
}

async fn count_users(db: &TestDatabase) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&db.pool)
        .await
        .expect("the users table is readable")
}
