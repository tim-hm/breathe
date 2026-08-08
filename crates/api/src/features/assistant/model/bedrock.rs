//! The real [`ModelClient`]: Anthropic's Messages API, served by Amazon Bedrock.
//!
//! The only file in this feature that knows a provider exists. Everything above
//! it — quota, breaker, validation, fallback — is written against the trait in
//! `super::model`, so changing provider is this file and two constants in
//! `config.rs`.
//!
//! Bedrock is called directly rather than through an intermediary, which is the
//! whole point of the arrangement: no third party sees a person's words in
//! transit, and `web/privacy.html` can name exactly one processor. The call is
//! signed with the EC2 instance profile that `infra/main.tf` already attaches,
//! found through the AWS SDK's default credential chain — so there is no key on
//! the box and no environment variable naming one.
//!
//! Two things about the request body are Bedrock's rather than Anthropic's: the
//! model is named in the URL instead of the body, and `anthropic_version`
//! replaces it there. Everything else is the Messages API as documented,
//! `cache_control` included — it marks the end of the prefix Bedrock caches,
//! and it is why `ModelRequest` splits the prompt in two rather than handing
//! over one string.

use std::time::{Duration, Instant};

use aws_credential_types::provider::ProvideCredentials as _;
use aws_sdk_bedrockruntime::config::Region;
use aws_sdk_bedrockruntime::config::timeout::TimeoutConfig;
use aws_sdk_bedrockruntime::error::ProvideErrorMetadata as _;
use aws_sdk_bedrockruntime::primitives::Blob;
use serde::{Deserialize, Serialize};

use super::{ChatRole, ModelClient, ModelError, ModelRequest, ModelStream, millis};
use crate::config;

/// Which shape of the Messages API this body is written in. Bedrock takes it in
/// place of `model`, which it reads from the URL instead. Not a date to keep
/// current — it names the request format, and Anthropic has published exactly
/// this one for Bedrock since the integration existed.
const ANTHROPIC_VERSION: &str = "bedrock-2023-05-31";

/// Bounds a whole non-streaming call, retries included. Generous enough for a
/// long reply on a slow day and short enough that a hung provider does not hold
/// the person's screen: the breaker needs failures to arrive to be able to trip
/// on them.
///
/// Applied per request rather than on the client, because the streaming path
/// must not carry it — there the same ceiling would cut a healthy answer
/// mid-sentence at 45 seconds of perfectly good reading.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);

/// Bounds reaching Bedrock at all. A connection that has not been accepted is a
/// hang with nothing to wait for, on either path.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Bounds the gap *between* reads, which is what "the provider stopped
/// answering" actually looks like on a stream. A working stream resets it on
/// every frame, so it bounds a hang without bounding a long explanation.
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// Bounds the credential lookup [`BedrockClient::connect`] does at boot.
///
/// The chain ends at the instance metadata endpoint, which answers in
/// milliseconds on the box and is simply absent on a laptop — but "absent" can
/// present as a hang rather than a refusal on a network that blackholes the
/// link-local address. Startup must not depend on which.
const CREDENTIAL_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// Chunks held between Bedrock's event stream and the client's.
///
/// Small: the point of streaming is that a chunk reaches the reader as it
/// arrives, and a deep buffer would let the decoder run ahead of a slow client
/// and hold the whole answer in memory instead.
const STREAM_BUFFER_FRAMES: usize = 16;

/// Talks to Bedrock.
pub struct BedrockClient {
    client: aws_sdk_bedrockruntime::Client,
}

impl BedrockClient {
    /// Builds a client, and proves this machine can sign for one.
    ///
    /// The proof is the point. Resolving credentials is otherwise lazy, so
    /// without this a laptop with no AWS identity would boot claiming the
    /// assistant is live and then fail every call until the breaker noticed —
    /// three wasted quota claims and a log line that lied. Failing here instead
    /// puts the process on the documented `DisabledModelClient` path, which is
    /// the same path a fresh clone and CI take.
    ///
    /// The credentials themselves are deliberately discarded: the SDK's own
    /// cache holds them and refreshes them before they expire, which an
    /// instance profile's six-hour lifetime requires and a copy kept here would
    /// not do.
    pub async fn connect() -> anyhow::Result<Self> {
        // rustls over ring, explicitly. The SDK's default HTTPS client selects
        // aws-lc-rs, which would put a second crypto backend in a binary that
        // already links ring through rustls for Postgres and Apple.
        let https = aws_smithy_http_client::Builder::new()
            .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(
                aws_smithy_http_client::tls::rustls_provider::CryptoMode::Ring,
            ))
            .build_https();

        let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(Region::new(config::BEDROCK_REGION))
            .http_client(https)
            .timeout_config(
                TimeoutConfig::builder()
                    .connect_timeout(CONNECT_TIMEOUT)
                    .read_timeout(READ_TIMEOUT)
                    .build(),
            )
            // Off deliberately. The SDK's default cuts a response that delivers
            // no bytes for five seconds, which is a sane rule for an S3 download
            // and the wrong one for a model that can think before it speaks.
            // READ_TIMEOUT above is this path's stall detector, at a length that
            // suits an answer being written.
            .stalled_stream_protection(
                aws_sdk_bedrockruntime::config::StalledStreamProtectionConfig::disabled(),
            )
            .load()
            .await;

        let provider = sdk
            .credentials_provider()
            .ok_or_else(|| anyhow::anyhow!("the AWS credential chain resolved to nothing"))?;

        tokio::time::timeout(CREDENTIAL_PROBE_TIMEOUT, provider.provide_credentials())
            .await
            .map_err(|_| {
                anyhow::anyhow!("the AWS credential chain did not answer within the probe timeout")
            })?
            .map_err(|error| anyhow::anyhow!("no AWS credentials are available: {error}"))?;

        Ok(Self {
            client: aws_sdk_bedrockruntime::Client::new(&sdk),
        })
    }
}

#[tonic::async_trait]
impl ModelClient for BedrockClient {
    async fn complete(&self, request: &ModelRequest) -> Result<String, ModelError> {
        let started = Instant::now();
        let body = encode(request)?;

        let response = self
            .client
            .invoke_model()
            .model_id(config::BEDROCK_MODEL_ID)
            .content_type("application/json")
            .accept("application/json")
            .body(Blob::new(body))
            .customize()
            // Every field restated rather than only the one being added: an
            // override layer replaces the base `TimeoutConfig` wholesale, so a
            // partial one would silently drop the connect and read bounds.
            .config_override(
                aws_sdk_bedrockruntime::Config::builder().timeout_config(
                    TimeoutConfig::builder()
                        .connect_timeout(CONNECT_TIMEOUT)
                        .read_timeout(READ_TIMEOUT)
                        .operation_timeout(REQUEST_TIMEOUT)
                        .build(),
                ),
            )
            .send()
            .await
            .map_err(|error| refused("the call did not complete", error.code()))?;

        let reply: MessagesResponse = serde_json::from_slice(&response.body.into_inner())
            .map_err(|error| ModelError::Failed(format!("the reply did not decode: {error}")))?;

        // One line per paid call, before the content is judged — the call was
        // billed whatever the reply turns out to say. `info` survives the
        // million-requests test because the daily allowance bounds how many of
        // these a person can cause, and nothing else in the process records
        // what the assistant costs.
        let usage = reply.usage.as_ref();
        tracing::info!(
            feature = "assistant",
            model = config::BEDROCK_MODEL_ID,
            duration_ms = millis(started.elapsed()),
            prompt_tokens = usage.map(|usage| usage.input_tokens),
            completion_tokens = usage.map(|usage| usage.output_tokens),
            cached_tokens = usage.map(|usage| usage.cache_read_input_tokens),
            "the model answered"
        );

        let text: String = reply
            .content
            .into_iter()
            .filter_map(|block| block.text)
            .collect();

        if text.trim().is_empty() {
            return Err(ModelError::Failed(
                "the reply carried no content".to_owned(),
            ));
        }
        Ok(text)
    }

    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError> {
        // Timed to the first chunk, which is the wait the reader experiences;
        // the rest of a stream is bounded by how fast they read. No token
        // counts: they arrive on the closing frame, long after this line.
        let mut started = Some(Instant::now());
        let body = encode(request)?;

        let response = self
            .client
            .invoke_model_with_response_stream()
            .model_id(config::BEDROCK_MODEL_ID)
            .content_type("application/json")
            .accept("application/json")
            .body(Blob::new(body))
            .send()
            .await
            .map_err(|error| refused("the call did not complete", error.code()))?;

        // A channel and a task rather than a generator: the receiver *is* the
        // stream, so a client that hangs up drops it and the decoder below
        // notices immediately.
        let mut events = response.body;
        let (sender, receiver) = tokio::sync::mpsc::channel(STREAM_BUFFER_FRAMES);

        tokio::spawn(async move {
            // A stream that opens and then yields nothing is a failure, not an
            // empty answer. Without this the receiver completes cleanly with no
            // frames, the RPC ends OK, and the client — which appends the
            // running total and only speaks up on a thrown error — shows the
            // person nothing at all for a message they watched themselves send.
            let mut answered = false;

            // Broken out of rather than returned from, so that the silence
            // check below sees every clean end. The `return`s inside are the
            // paths that must skip it: either nobody is listening any more, or
            // a failure is already on its way down the channel.
            'stream: loop {
                // Races the next frame against the client going away. Without
                // the second arm, a reader who closed the screen mid-answer is
                // only noticed on the following `send`, which for a slow
                // provider can be the rest of the read timeout away.
                let frame = tokio::select! {
                    frame = events.recv() => frame,
                    () = sender.closed() => return,
                };

                let frame = match frame {
                    Ok(Some(frame)) => frame,
                    // The stream ended. Bedrock always closes after
                    // `message_stop`, so this is the ordinary exit.
                    Ok(None) => break 'stream,
                    Err(error) => {
                        // Sent without logging it here: `model_chunks` logs
                        // every `Err` it forwards, and this message carries
                        // what there is to carry, so a line here would be the
                        // same event recorded twice.
                        let broken = refused("the stream broke mid-answer", error.code());
                        drop(sender.send(Err(broken)).await);
                        return;
                    }
                };

                let payload = frame
                    .as_chunk()
                    .ok()
                    .and_then(|chunk| chunk.bytes.as_ref())
                    .map(Blob::as_ref);

                // A variant this SDK version does not know, or a chunk with no
                // payload. Neither is a failure and neither carries text.
                let Some(payload) = payload else { continue };

                match parse_event(payload) {
                    Event::Done => break 'stream,
                    Event::Failed(kind) => {
                        drop(sender.send(Err(mid_stream_failure(kind.as_deref()))).await);
                        return;
                    }
                    Event::Text(text) if !text.is_empty() => {
                        if let Some(started) = started.take() {
                            tracing::info!(
                                feature = "assistant",
                                model = config::BEDROCK_MODEL_ID,
                                duration_ms = millis(started.elapsed()),
                                "the model started answering"
                            );
                        }

                        // Whitespace is forwarded — it is the space between
                        // words — but it does not count as having answered, the
                        // same judgement `complete` makes with `trim`. A stream
                        // of nothing but blanks is silence with extra steps, and
                        // lands as an empty coach turn.
                        let said_something = !text.trim().is_empty();

                        if sender.send(Ok(text)).await.is_err() {
                            return;
                        }
                        answered = answered || said_something;
                    }
                    Event::Text(_) | Event::Ignored => {}
                }
            }

            if !answered {
                drop(
                    sender
                        .send(Err(ModelError::Failed(
                            "the provider's stream carried no content".to_owned(),
                        )))
                        .await,
                );
            }
        });

        Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(
            receiver,
        )))
    }
}

/// Names a provider failure by its error code and nothing else.
///
/// The message is deliberately never read. A moderation refusal is the likeliest
/// failure on this path and routinely quotes the input back, so any excerpt of a
/// provider message is the person's own words with a length limit on them — in a
/// log line, or in an error string that travels. A code such as
/// `ThrottlingException` or `ValidationException` is what somebody debugging
/// actually needs, and it cannot contain prose.
fn refused(context: &str, code: Option<&str>) -> ModelError {
    ModelError::Failed(match code {
        Some(code) => format!("{context}: {code}"),
        None => context.to_owned(),
    })
}

/// A failure Bedrock reported inside an open stream, named by its type.
///
/// Named rather than inline to keep the decoder's `Failed` arm a single line;
/// the type is all there is to report, for the reason [`refused`] gives.
fn mid_stream_failure(kind: Option<&str>) -> ModelError {
    ModelError::Failed(match kind {
        Some(kind) => format!("the provider reported {kind} mid-stream"),
        None => "the provider reported a failure mid-stream".to_owned(),
    })
}

/// Serializes one request body.
///
/// Fallible only in the way `serde_json` is fallible over a struct of owned
/// strings, which is to say never in practice — but a `Failed` here beats an
/// unwrap, and the caller already has a branch for it.
fn encode(request: &ModelRequest) -> Result<Vec<u8>, ModelError> {
    serde_json::to_vec(&messages_request(request))
        .map_err(|error| ModelError::Failed(format!("the request body did not encode: {error}")))
}

/// One decoded stream frame, reduced to what matters.
enum Event {
    /// Text to append to the explanation.
    Text(String),
    /// The provider said the stream is over.
    Done,
    /// The provider reported a failure inside a stream it had already opened —
    /// how a throttle or an upstream outage arrives once the response is
    /// committed to a 200 and the headers are long gone.
    Failed(Option<String>),
    /// A ping, a block boundary, or a usage report — every stream has several,
    /// and none of them is an error.
    Ignored,
}

/// Reads one event frame.
///
/// A frame that does not parse is skipped rather than failing the stream: the
/// person is reading an explanation, and losing a sentence beats losing the rest
/// of it. The error arm is checked before the delta for the reason it exists —
/// an error read as `Ignored` is a stream that simply stopped, which the caller
/// cannot tell from a finished answer.
fn parse_event(payload: &[u8]) -> Event {
    let Ok(frame) = serde_json::from_slice::<StreamFrame>(payload) else {
        return Event::Ignored;
    };

    match frame.kind.as_str() {
        "error" => Event::Failed(frame.error.and_then(|error| error.kind)),
        "message_stop" => Event::Done,
        "content_block_delta" => frame
            .delta
            .and_then(|delta| delta.text)
            .map_or(Event::Ignored, Event::Text),
        _ => Event::Ignored,
    }
}

/// Builds the body for one call, borrowing the prompt rather than copying it.
///
/// A function rather than inline in the two trait methods so that a test can pin
/// the JSON the send actually puts on the wire, and so the two paths cannot
/// drift apart — on this API they differ only in which operation carries the
/// bytes. Asserting on a body assembled by the test instead would pass happily
/// while production sent something else.
fn messages_request(request: &ModelRequest) -> MessagesRequest<'_> {
    let mut messages = vec![Message {
        role: "user",
        content: vec![Block {
            kind: "text",
            text: &request.instruction,
            cache_control: None,
        }],
    }];

    // The conversation as genuinely attributed speech: each turn is its own
    // user or assistant message, never a transcript serialised into the
    // instruction. The model treats an assistant message as words it already
    // said, which is what makes an instruction smuggled into one land as
    // somebody's speech rather than as the caller's authority. Consecutive
    // same-role messages are legal here, so the instruction message above and a
    // leading person turn need no glue.
    messages.extend(request.turns.iter().map(|turn| Message {
        role: match turn.role {
            ChatRole::Person => "user",
            ChatRole::Coach => "assistant",
        },
        content: vec![Block {
            kind: "text",
            text: &turn.text,
            cache_control: None,
        }],
    }));

    MessagesRequest {
        anthropic_version: ANTHROPIC_VERSION,
        max_tokens: request.max_tokens,
        system: vec![Block {
            kind: "text",
            text: &request.cacheable_prefix,
            // Marks everything up to here as the cacheable prefix, which on
            // this model is billed at a fraction on the next call. Bedrock
            // reads the marker itself; nothing else in the body depends on it.
            cache_control: Some(CacheControl { kind: "ephemeral" }),
        }],
        messages,
    }
}

#[derive(Serialize)]
struct MessagesRequest<'a> {
    anthropic_version: &'static str,
    max_tokens: i32,
    system: Vec<Block<'a>>,
    messages: Vec<Message<'a>>,
}

#[derive(Serialize)]
struct Message<'a> {
    role: &'static str,
    content: Vec<Block<'a>>,
}

#[derive(Serialize)]
struct Block<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    text: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    cache_control: Option<CacheControl>,
}

/// Marks the end of the prefix worth caching.
#[derive(Serialize)]
struct CacheControl {
    #[serde(rename = "type")]
    kind: &'static str,
}

#[derive(Deserialize)]
struct MessagesResponse {
    content: Vec<ResponseBlock>,
    /// What the call cost. Optional because a reply that omits it is not a
    /// failed call, only an unmeasured one.
    #[serde(default)]
    usage: Option<Usage>,
}

/// One block of a finished reply. `text` is absent on any block that is not
/// text, which this request cannot provoke today and a future one might.
#[derive(Deserialize)]
struct ResponseBlock {
    #[serde(default)]
    text: Option<String>,
}

/// The token counts behind one call — the safe substitute for logging what was
/// asked and what came back.
// The shared `tokens` suffix is the wire's, not a naming habit: these are
// Anthropic's field names and renaming them would mean three `serde(rename)`
// attributes to say the same thing less directly.
#[allow(clippy::struct_field_names)]
#[derive(Deserialize)]
struct Usage {
    #[serde(default)]
    input_tokens: u32,
    #[serde(default)]
    output_tokens: u32,
    /// The part of the prefix served from cache, and the only evidence that the
    /// `cache_control` marker above is worth splitting the prompt for.
    #[serde(default)]
    cache_read_input_tokens: u32,
}

/// One frame of the event stream, in the one shape that covers all of them.
///
/// Flattened rather than an enum over `type`: the frames carry disjoint fields,
/// every field here is optional, and a shape surprise on a field this decoder
/// does not read would otherwise fail the whole frame's parse — which reads as
/// [`Event::Ignored`], the silent truncation the error arm exists to prevent.
#[derive(Deserialize)]
struct StreamFrame {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    delta: Option<Delta>,
    #[serde(default)]
    error: Option<StreamError>,
}

#[derive(Deserialize)]
struct Delta {
    #[serde(default)]
    text: Option<String>,
}

/// A mid-stream failure, reduced to the one field that is safe to keep.
///
/// The sibling `message` is deliberately not read, for the reason [`refused`]
/// gives: it is where a moderation refusal quotes the person's own words back.
#[derive(Deserialize)]
struct StreamError {
    #[serde(rename = "type", default)]
    kind: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::features::assistant::model::ChatTurn;

    fn request() -> ModelRequest {
        ModelRequest {
            cacheable_prefix: "the catalogue".to_owned(),
            instruction: "a profile".to_owned(),
            turns: vec![],
            max_tokens: 64,
        }
    }

    /// The two ways this body differs from the Messages API as published, and
    /// both are absolute: Bedrock rejects a body without `anthropic_version`,
    /// and rejects one carrying `model` — which it reads from the URL. Pinned on
    /// the serialised JSON because that is what leaves the process.
    #[test]
    fn the_body_is_the_bedrock_messages_shape() {
        let body = serde_json::to_value(messages_request(&request()))
            .expect("the request body serialises");

        assert_eq!(body["anthropic_version"], ANTHROPIC_VERSION);
        assert_eq!(body["max_tokens"], 64);
        assert!(
            body.get("model").is_none(),
            "the model is named in the URL, and a `model` here is rejected: {body}"
        );
    }

    /// Dropped or misplaced, the marker fails open: the call simply runs
    /// uncached, nothing reports it, and the only sign is the bill. It belongs
    /// on the system prefix and nowhere else — a marker on a per-caller message
    /// writes a cache entry that is never read back.
    #[test]
    fn only_the_cacheable_prefix_is_marked() {
        let body = serde_json::to_value(messages_request(&request()))
            .expect("the request body serialises");

        assert_eq!(
            body["system"][0]["cache_control"],
            serde_json::json!({ "type": "ephemeral" })
        );
        assert_eq!(body["system"][0]["text"], "the catalogue");
        assert!(
            body["messages"][0].get("cache_control").is_none(),
            "the instruction differs per caller and must not be marked: {body}"
        );
    }

    /// The conversation reaches the model as real speech rather than a
    /// transcript, which is what makes an instruction inside a turn arrive as
    /// somebody's words instead of the caller's authority.
    #[test]
    fn turns_are_attributed_messages() {
        let mut request = request();
        request.turns = vec![
            ChatTurn {
                role: ChatRole::Person,
                text: "I wake at 3am.".to_owned(),
            },
            ChatTurn {
                role: ChatRole::Coach,
                text: "Try a longer exhale.".to_owned(),
            },
        ];

        let body =
            serde_json::to_value(messages_request(&request)).expect("the request body serialises");

        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"][0]["text"], "a profile");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][2]["role"], "assistant");
    }

    /// The three shapes every stream carries, and the ones that must not be
    /// mistaken for text: a block boundary and a ping arrive on every stream.
    #[test]
    fn only_content_deltas_become_text() {
        assert!(matches!(
            parse_event(br#"{"type":"message_stop"}"#),
            Event::Done
        ));
        assert!(matches!(parse_event(br#"{"type":"ping"}"#), Event::Ignored));
        assert!(matches!(
            parse_event(br#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            Event::Ignored
        ));
        assert!(matches!(
            parse_event(br#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#),
            Event::Ignored
        ));

        let Event::Text(text) = parse_event(
            br#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a long"}}"#,
        ) else {
            panic!("a content delta is text");
        };
        assert_eq!(text, "a long");
    }

    /// A malformed frame is skipped rather than failing the stream: the person
    /// is reading an explanation, and losing a sentence beats losing the rest
    /// of it.
    #[test]
    fn a_malformed_frame_is_skipped() {
        assert!(matches!(parse_event(b"{not json"), Event::Ignored));
    }

    /// How a throttle or an upstream outage arrives once the response has
    /// already committed to a 200. Read as `Ignored` this decodes as a stream
    /// that simply stopped, which the caller cannot tell from a finished answer.
    #[test]
    fn a_mid_stream_error_frame_fails_the_stream() {
        let Event::Failed(kind) = parse_event(
            br#"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#,
        ) else {
            panic!("an error frame fails the stream");
        };
        assert_eq!(kind.as_deref(), Some("overloaded_error"));

        assert!(matches!(
            parse_event(br#"{"type":"error","error":{"message":"unwell"}}"#),
            Event::Failed(None)
        ));
    }

    /// A moderation refusal quotes the input back in `message`, so neither the
    /// error string nor anything derived from it may carry that field. The type
    /// is the whole reportable part.
    #[test]
    fn a_reported_failure_never_carries_provider_prose() {
        let Event::Failed(kind) = parse_event(
            br#"{"type":"error","error":{"type":"invalid_request_error","message":"flagged: my private words"}}"#,
        ) else {
            panic!("an error frame fails the stream");
        };

        let reported = mid_stream_failure(kind.as_deref()).to_string();
        assert!(reported.contains("invalid_request_error"));
        assert!(!reported.contains("my private words"), "{reported}");
    }
}
