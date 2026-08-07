//! A disposable database, the production router over it, and a gRPC-Web client.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use api::assistant::{
    DisabledModelClient, ModelClient, ModelError, ModelRequest, ModelStream, daily_model_calls,
};
use api::config::{Config, Environment};
use api::entitlement::{AppStoreVerifier, Tier, TransactionVerifier};
use api::state::AppState;
use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{Request, StatusCode, header};
use prost::Message;
use sqlx::PgPool;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use tower::ServiceExt;

/// Prefix on every database this harness creates.
///
/// It is what makes pointing these tests at the development database
/// structurally impossible rather than merely discouraged: the name is derived
/// from `DATABASE_URL` by *replacing* its database, so the configured
/// connection string can never be used as-is. These tests drop wholesale.
const TEST_DATABASE_PREFIX: &str = "ond_test_";

/// Postgres truncates identifiers past this and would silently collide two
/// tests whose names share a long prefix.
const MAX_IDENTIFIER_BYTES: usize = 63;

/// A freshly migrated and seeded database, owned by one test.
pub struct TestDatabase {
    pub pool: PgPool,
}

impl TestDatabase {
    /// Creates `ond_test_<test_name>`, migrated and seeded.
    ///
    /// The name is deterministic rather than random, and creation drops any
    /// previous instance: a test that fails leaves its database behind for
    /// post-mortem inspection, and the next run of that same test reclaims it.
    /// The set of test databases is therefore bounded by the number of tests
    /// rather than growing with every run.
    pub async fn create(test_name: &str) -> Self {
        let name = format!("{TEST_DATABASE_PREFIX}{test_name}");
        assert!(
            name.len() <= MAX_IDENTIFIER_BYTES,
            "test name `{test_name}` makes an over-long database identifier"
        );

        let options = PgConnectOptions::from_str(&database_url())
            .expect("DATABASE_URL is a valid Postgres connection string");

        let maintenance = migrate::connect_maintenance(&options)
            .await
            .expect("Postgres is reachable — is `mise run dev:db` running?");

        // `FORCE` terminates connections a previously killed test process left
        // open; without it a crashed run wedges its own database until restart.
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE)",
            migrate::quote_identifier(&name)
        )))
        .execute(&maintenance)
        .await
        .expect("the previous test database drops");

        migrate::create_database_if_absent(&options, &name)
            .await
            .expect("the test database is created");

        let pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.database(&name))
            .await
            .unwrap_or_else(|e| panic!("failed to connect to `{name}`: {e}"));

        migrate::apply(&pool)
            .await
            .expect("the schema and seed apply to a fresh database");

        Self { pool }
    }

    /// The router the binary serves, over this database.
    ///
    /// No language model behind the seam: a test that is not about the
    /// assistant must behave the same whether or not a key happens to be in the
    /// environment, and a suite that could reach the network is a suite that
    /// fails on a train. `DisabledModelClient` is not a stub for the occasion —
    /// it is what a deployment without a key runs.
    pub fn app(&self) -> Router {
        build_app(self.pool.clone())
    }

    /// The same router with a scripted model behind the seam.
    ///
    /// Paired with [`Self::app`] rather than folded into one argument, for the
    /// same reason `call_grpc_web` is paired with `call_grpc_web_with`: the
    /// model is the one thing that varies, and twenty unrelated tests should not
    /// carry it.
    pub fn app_with_model(&self, assistant: Arc<dyn ModelClient>) -> Router {
        build_app_with(self.pool.clone(), assistant, Arc::new(AppStoreVerifier))
    }

    /// The same router with a scripted App Store verifier behind the seam.
    ///
    /// Paired with [`Self::app`] for the same reason as [`Self::app_with_model`]
    /// — and needed for the same reason the model seam is: no test can hold an
    /// Apple-signed transaction, so a suite driven through the real verifier
    /// could only ever assert that everything is rejected.
    pub fn app_with_verifier(&self, entitlement: Arc<dyn TransactionVerifier>) -> Router {
        build_app_with(
            self.pool.clone(),
            Arc::new(DisabledModelClient),
            entitlement,
        )
    }
}

/// One person's daily model allowance, in the `usize` a call count is compared
/// against. Zero for a tier that does not buy the model at all.
///
/// Derived rather than written out, so a test says which tier it is asserting
/// about and the numbers stay in `features::assistant::types` where the product
/// decision lives.
pub fn allowance(tier: Tier) -> usize {
    daily_model_calls(tier).map_or(0, |calls| {
        usize::try_from(calls).expect("an allowance is never negative")
    })
}

/// Puts somebody on a paid tier by writing the columns `EntitlementService`
/// writes.
///
/// Straight into the row rather than through a submission, for the suites that
/// want a subscriber without caring how they became one. In the harness because
/// two of them do — and because the column names are a raw string here, so a
/// schema move that renames one is a runtime failure rather than a compile
/// error, and it should only be able to happen in one place.
pub async fn subscribe(pool: &PgPool, user: &str, tier: &str) {
    sqlx::query(
        "INSERT INTO users (id, subscription_tier, subscription_until)
         VALUES ($1, $2::subscription_tier, now() + interval '1 year')
         ON CONFLICT (id) DO UPDATE SET
           subscription_tier = EXCLUDED.subscription_tier,
           subscription_until = EXCLUDED.subscription_until",
    )
    .bind(user.parse::<uuid::Uuid>().expect("a valid uuid"))
    .bind(tier)
    .execute(pool)
    .await
    .expect("the subscription is written");
}

/// A model that answers from a script and records every request it was asked.
///
/// The record is what makes the rest of the feature observable from outside.
/// The quota and the breaker are supposed to stop a call from happening at all,
/// and a test that only checked the response could not tell "answered from the
/// rules" apart from "called the model and ignored it" — that is [`Self::calls`].
/// The prompt builder decides what the model is told about a person, and a test
/// that only checked the reply could not see it — that is [`Self::requests`].
///
/// In the harness rather than in one suite because two of them need it — the
/// assistant's, which is about what the model says, and the entitlement's, which
/// is about how often it may be asked.
pub struct ScriptedModel {
    /// Replies in order; the last one repeats once the script runs out.
    replies: Mutex<Vec<Result<String, ModelError>>>,
    /// Every request received, in the order the calls arrived.
    requests: Mutex<Vec<ModelRequest>>,
}

impl ScriptedModel {
    /// `next` repeats a sole entry forever, so "always" is a one-element script.
    pub fn always(reply: Result<String, ModelError>) -> Arc<Self> {
        Self::script(vec![reply])
    }

    pub fn script(replies: Vec<Result<String, ModelError>>) -> Arc<Self> {
        Arc::new(Self {
            replies: Mutex::new(replies),
            requests: Mutex::new(Vec::new()),
        })
    }

    pub fn calls(&self) -> usize {
        self.lock_requests().len()
    }

    /// What the model was asked, for asserting on the prompt itself.
    ///
    /// Copies rather than a guard, so no lock ever leaves the harness — a held
    /// guard would quietly deadlock the next capture, and a test double two
    /// suites share should not come with a locking rule.
    pub fn requests(&self) -> Vec<ModelRequest> {
        self.lock_requests().iter().map(copy_request).collect()
    }

    fn lock_requests(&self) -> std::sync::MutexGuard<'_, Vec<ModelRequest>> {
        self.requests.lock().expect("the requests are not poisoned")
    }

    fn next(&self, request: &ModelRequest) -> Result<String, ModelError> {
        self.lock_requests().push(copy_request(request));

        let mut replies = self.replies.lock().expect("the script is not poisoned");
        if replies.len() > 1 {
            replies.remove(0)
        } else {
            match replies.first() {
                Some(Ok(reply)) => Ok(reply.clone()),
                Some(Err(_)) | None => Err(ModelError::Failed("scripted failure".to_owned())),
            }
        }
    }
}

/// Field by field because `ModelRequest` does not implement `Clone`, and the
/// production seam should not grow one for a test double's sake.
fn copy_request(request: &ModelRequest) -> ModelRequest {
    ModelRequest {
        cacheable_prefix: request.cacheable_prefix.clone(),
        instruction: request.instruction.clone(),
        turns: request.turns.clone(),
        max_tokens: request.max_tokens,
    }
}

#[tonic::async_trait]
impl ModelClient for ScriptedModel {
    async fn complete(&self, request: &ModelRequest) -> Result<String, ModelError> {
        self.next(request)
    }

    /// One chunk per line, so a test can assert the client received them in the
    /// order the model wrote them.
    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError> {
        let reply = self.next(request)?;
        let chunks: Vec<Result<String, ModelError>> =
            reply.lines().map(|line| Ok(line.to_owned())).collect();

        Ok(Box::pin(tokio_stream::iter(chunks)))
    }
}

/// Assembles the production router over an arbitrary pool.
///
/// Separate from [`TestDatabase::app`] so a test can supply a pool that is
/// deliberately broken — see `health.rs`.
pub fn build_app(pool: PgPool) -> Router {
    build_app_with(
        pool,
        Arc::new(DisabledModelClient),
        Arc::new(AppStoreVerifier),
    )
}

/// [`build_app`], plus both of the seams a deployment chooses at startup.
pub fn build_app_with(
    pool: PgPool,
    assistant: Arc<dyn ModelClient>,
    entitlement: Arc<dyn TransactionVerifier>,
) -> Router {
    let config = Config {
        environment: Environment::Dev,
        // Read only while building the pool, which the caller has already done.
        // Nothing downstream of `AppState` looks at it.
        database_url: String::new(),
        port: 0,
        // Never read: the model client is supplied directly, so no test can
        // reach a provider even on a machine where the key is exported.
        openrouter_api_key: None,
    };

    api::build_app(AppState::new(pool, config, assistant, entitlement))
        .expect("the router assembles")
}

fn database_url() -> String {
    std::env::var("DATABASE_URL").expect(
        "DATABASE_URL is not set — run these through `mise run test:e2e`, which supplies it",
    )
}

/// One flag byte, then a four-byte big-endian length.
const FRAME_HEADER_LEN: usize = 5;

/// The high bit of the flag byte marks a trailer frame rather than a message.
const TRAILER_FLAG: u8 = 0x80;

/// Generous enough for the whole catalogue and small enough that a runaway
/// response fails the test instead of the machine.
const MAX_RESPONSE_BYTES: usize = 1 << 20;

/// A deframed gRPC-Web response.
pub struct GrpcWebResponse<T> {
    /// Absent when the call failed before producing a message, which is what a
    /// trailers-only error response looks like.
    pub message: Option<T>,
    /// The `grpc-status` code. `0` is success and the rest match `tonic::Code`.
    pub status: i32,
    /// The `grpc-message` text, empty on success.
    pub status_message: String,
}

impl<T> GrpcWebResponse<T> {
    /// The message, asserting the call succeeded.
    pub fn into_ok(self) -> T {
        assert_eq!(
            self.status, 0,
            "grpc-status {}: {}",
            self.status, self.status_message
        );
        self.message
            .expect("a successful call carries a message frame")
    }
}

/// Calls `path` the way the iOS client does.
///
/// gRPC-Web is an HTTP POST carrying a length-prefixed protobuf frame, with the
/// call's outcome in trailers rather than the HTTP status — so a failed call
/// still returns 200 and a client that ignores the trailers sees success. That
/// asymmetry is the whole reason this goes over the real framing instead of
/// calling the service function.
///
/// Driving the router with `oneshot` rather than binding a port is deliberate:
/// the layer stack under test (`GrpcWebLayer`, CORS, tonic's routes) is the
/// whole of the server's behaviour, and a listener would only add hyper, a
/// background task, and a shutdown race.
pub async fn call_grpc_web<Req, Res>(app: Router, path: &str, request: &Req) -> GrpcWebResponse<Res>
where
    Req: Message,
    Res: Message + Default,
{
    call_grpc_web_with(app, path, request, &[]).await
}

/// [`call_grpc_web`], plus the headers the client would send alongside.
///
/// Separate rather than a fourth parameter on every call site: identity is the
/// only thing that travels out-of-band, and the tests that do not exercise it
/// read better without an empty slice in them.
pub async fn call_grpc_web_with<Req, Res>(
    app: Router,
    path: &str,
    request: &Req,
    headers: &[(&str, &str)],
) -> GrpcWebResponse<Res>
where
    Req: Message,
    Res: Message + Default,
{
    let streamed = call_grpc_web_stream_with(app, path, request, headers).await;

    assert!(
        streamed.messages.len() <= 1,
        "a unary call answered with {} messages",
        streamed.messages.len()
    );

    GrpcWebResponse {
        message: streamed.messages.into_iter().next(),
        status: streamed.status,
        status_message: streamed.status_message,
    }
}

/// Every message a server-streaming call produced, plus how it ended.
///
/// Separate from [`GrpcWebResponse`] because the thing being asserted is
/// different: a unary call has one message or none, and a stream has an ordered
/// list whose order is the point.
pub struct GrpcWebStream<T> {
    /// In the order they arrived on the wire.
    pub messages: Vec<T>,
    pub status: i32,
    pub status_message: String,
}

impl<T> GrpcWebStream<T> {
    /// The messages, asserting the stream ended cleanly.
    pub fn into_ok(self) -> Vec<T> {
        assert_eq!(
            self.status, 0,
            "grpc-status {}: {}",
            self.status, self.status_message
        );
        self.messages
    }
}

/// Calls a server-streaming method the way the iOS client does.
///
/// gRPC-Web sends a server stream as several length-prefixed message frames in
/// one response body, followed by the trailer frame — so the whole stream is
/// readable here without a listener, and the frames arrive in the order the
/// server wrote them. That ordering is exactly what a client accumulating an
/// explanation depends on, and it is only observable through the real framing.
pub async fn call_grpc_web_stream_with<Req, Res>(
    app: Router,
    path: &str,
    request: &Req,
    headers: &[(&str, &str)],
) -> GrpcWebStream<Res>
where
    Req: Message,
    Res: Message + Default,
{
    let mut builder =
        Request::post(path).header(header::CONTENT_TYPE, "application/grpc-web+proto");
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }

    let response = app
        .oneshot(
            builder
                .body(Body::from(frame(request)))
                .expect("a valid request"),
        )
        .await
        .expect("the router is infallible");

    // Anything other than 200 is a transport-level failure — a path tonic does
    // not route, or a request `GrpcWebLayer` refused to unwrap.
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "gRPC-Web reports call outcomes in trailers, so {path} should answer 200 either way"
    );

    // tonic answers an error that occurs before the response body with headers
    // alone, and a later one with a trailer frame. Both arrive here.
    let mut trailers: HashMap<String, String> = response
        .headers()
        .iter()
        .filter(|(name, _)| name.as_str().starts_with("grpc-"))
        .filter_map(|(name, value)| {
            Some((name.as_str().to_owned(), value.to_str().ok()?.to_owned()))
        })
        .collect();

    let body = axum::body::to_bytes(response.into_body(), MAX_RESPONSE_BYTES)
        .await
        .expect("the response body is readable");

    let messages = deframe(&body, &mut trailers);

    let status = trailers
        .get("grpc-status")
        .and_then(|value| value.parse().ok())
        .expect("the response carries a grpc-status, in a header or a trailer frame");

    GrpcWebStream {
        messages,
        status,
        status_message: trailers.get("grpc-message").cloned().unwrap_or_default(),
    }
}

fn frame(message: &impl Message) -> Bytes {
    let payload = message.encode_to_vec();
    let length = u32::try_from(payload.len()).expect("a request smaller than 4 GiB");

    let mut framed = Vec::with_capacity(FRAME_HEADER_LEN + payload.len());
    framed.push(0);
    framed.extend_from_slice(&length.to_be_bytes());
    framed.extend_from_slice(&payload);

    Bytes::from(framed)
}

/// Walks the frames in `body`, decoding every message and folding any trailer
/// frame into `trailers`.
///
/// A `Vec` rather than one message because a server stream writes several into
/// the same body; a unary call produces a list of one.
fn deframe<Res: Message + Default>(
    body: &[u8],
    trailers: &mut HashMap<String, String>,
) -> Vec<Res> {
    let mut messages = Vec::new();
    let mut rest = body;

    while rest.len() >= FRAME_HEADER_LEN {
        let flags = rest[0];
        let length = u32::from_be_bytes(
            rest[1..FRAME_HEADER_LEN]
                .try_into()
                .expect("a four-byte slice"),
        );
        let length = usize::try_from(length).expect("a frame that fits in memory");

        let end = FRAME_HEADER_LEN + length;
        assert!(
            end <= rest.len(),
            "frame claims {length} bytes it does not have"
        );
        let payload = &rest[FRAME_HEADER_LEN..end];
        rest = &rest[end..];

        if flags & TRAILER_FLAG == 0 {
            messages.push(Res::decode(payload).expect("the message frame decodes"));
        } else {
            let text = std::str::from_utf8(payload).expect("trailers are UTF-8");
            for line in text.lines() {
                if let Some((name, value)) = line.split_once(':') {
                    trailers.insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
                }
            }
        }
    }

    assert!(rest.is_empty(), "trailing bytes after the last frame");
    messages
}
