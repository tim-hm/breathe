//! The real [`ModelClient`]: `OpenRouter`'s chat-completions API.
//!
//! The only file in this feature that knows a provider exists. Everything above
//! it — quota, breaker, validation, fallback — is written against the trait in
//! `super::model`, so changing provider is this file and two constants in
//! `config.rs`.
//!
//! `OpenAI`-shaped request and response, which is what `OpenRouter` serves for
//! every model it routes to. The one provider-specific detail is
//! `cache_control`, which `OpenRouter` forwards to Anthropic models: it marks the
//! end of the prefix that should be cached, and it is why `ModelRequest` splits
//! the prompt in two rather than handing over one string.

use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt as _;

use super::{ChatRole, ModelClient, ModelError, ModelRequest, ModelStream, millis};
use crate::config;

/// Bounds a whole non-streaming call. Generous enough for a long reply on a slow
/// day and short enough that a hung provider does not hold the person's screen:
/// the breaker needs failures to arrive to be able to trip on them.
///
/// Applied per request rather than on the client, because the streaming path
/// must not carry it — there the same ceiling would cut a healthy answer
/// mid-sentence at 45 seconds of perfectly good reading.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);

/// Bounds reaching the provider at all. A connection that has not been accepted
/// is a hang with nothing to wait for, on either path.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Bounds the gap *between* bytes, which is what "the provider stopped
/// answering" actually looks like on a stream. A working stream resets it on
/// every chunk, so it bounds a hang without bounding a long explanation.
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// The provider's own handle on a call, echoed on every response. Logged when
/// one fails, because it is what lets somebody raise that call with
/// `OpenRouter`.
const REQUEST_ID_HEADER: &str = "x-request-id";

/// Chunks held between the provider's stream and the client's.
///
/// Small: the point of streaming is that a chunk reaches the reader as it
/// arrives, and a deep buffer would let the decoder run ahead of a slow client
/// and hold the whole answer in memory instead.
const STREAM_BUFFER_FRAMES: usize = 16;

/// Talks to `OpenRouter`.
pub struct OpenRouterClient {
    http: reqwest::Client,
    /// The full endpoint, joined once. Rebuilding it per call would re-parse a
    /// URL that cannot change.
    endpoint: String,
    /// The bearer token, held here and nowhere else. It is never logged, never
    /// returned in an error, and never reaches a client — the whole reason the
    /// model is called server-side rather than from the app.
    api_key: String,
}

impl OpenRouterClient {
    /// Builds a client around one long-lived connection pool.
    ///
    /// Fails when the `reqwest::Client` cannot be built, which in practice means
    /// the TLS backend failed to initialise — a boot-time fault, and one the
    /// caller answers by running without an assistant rather than refusing to
    /// serve the rest of the API. The error travels rather than being dropped:
    /// that caller's log line is the only account of why the assistant stayed
    /// quiet for the life of the process.
    pub fn new(api_key: &str) -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .build()?;

        Ok(Self {
            http,
            endpoint: format!("{}/chat/completions", config::OPENROUTER_BASE_URL),
            api_key: api_key.to_owned(),
        })
    }

    /// Sends one chat-completions request.
    ///
    /// Shared by both trait methods because they differ only in `stream` and in
    /// what they do with the body — and because the auth headers, the model id,
    /// and the cache boundary must not be able to drift apart between the two.
    async fn post(
        &self,
        request: &ModelRequest,
        streaming: bool,
    ) -> Result<reqwest::Response, ModelError> {
        let mut messages = vec![
            Message {
                role: "system",
                content: vec![Part {
                    kind: "text",
                    text: &request.cacheable_prefix,
                    // Marks everything up to here as the cacheable prefix.
                    // On an Anthropic model OpenRouter passes this through
                    // verbatim; a provider that does not understand it
                    // ignores the field, so this is safe on every route.
                    cache_control: Some(CacheControl { kind: "ephemeral" }),
                }],
            },
            Message {
                role: "user",
                content: vec![Part {
                    kind: "text",
                    text: &request.instruction,
                    cache_control: None,
                }],
            },
        ];

        // The conversation as genuinely attributed speech: each turn is its
        // own user or assistant message, never a transcript serialised into
        // the instruction. A provider treats an assistant message as words the
        // model already said, which is what makes an instruction smuggled into
        // one land as somebody's speech rather than as the caller's authority.
        // Consecutive same-role messages are legal on this endpoint, so the
        // instruction message above and a leading person turn need no glue.
        messages.extend(request.turns.iter().map(|turn| Message {
            role: match turn.role {
                ChatRole::Person => "user",
                ChatRole::Coach => "assistant",
            },
            content: vec![Part {
                kind: "text",
                text: &turn.text,
                cache_control: None,
            }],
        }));

        let body = ChatRequest {
            model: config::OPENROUTER_MODEL_ID,
            max_tokens: request.max_tokens,
            stream: streaming,
            messages,
        };

        let mut call = self
            .http
            .post(&self.endpoint)
            .bearer_auth(&self.api_key)
            .json(&body);
        if !streaming {
            call = call.timeout(REQUEST_TIMEOUT);
        }

        let response = call.send().await.map_err(|error| {
            ModelError::Failed(format!("the request did not complete: {error}"))
        })?;

        let status = response.status();
        if !status.is_success() {
            // The body is not read at all: a moderation refusal is the likeliest
            // failure here and routinely quotes the input back, so any excerpt
            // of it is the person's own words with a length limit on them.
            tracing::warn!(
                feature = "assistant",
                %status,
                request_id = response
                    .headers()
                    .get(REQUEST_ID_HEADER)
                    .and_then(|value| value.to_str().ok()),
                "the model provider refused the call"
            );
            return Err(ModelError::Failed(format!(
                "the provider answered {status}"
            )));
        }

        Ok(response)
    }
}

#[tonic::async_trait]
impl ModelClient for OpenRouterClient {
    async fn complete(&self, request: &ModelRequest) -> Result<String, ModelError> {
        let started = Instant::now();
        let response = self.post(request, false).await?;

        let body: ChatResponse = response
            .json()
            .await
            .map_err(|error| ModelError::Failed(format!("the reply did not decode: {error}")))?;

        // One line per paid call, before the content is judged — the call was
        // billed whatever the reply turns out to say. `info` survives the
        // million-requests test because the daily allowance bounds how many of
        // these a person can cause, and nothing else in the process records
        // what the assistant costs.
        let usage = body.usage.as_ref();
        tracing::info!(
            feature = "assistant",
            model = config::OPENROUTER_MODEL_ID,
            duration_ms = millis(started.elapsed()),
            prompt_tokens = usage.map(|usage| usage.prompt_tokens),
            completion_tokens = usage.map(|usage| usage.completion_tokens),
            cached_tokens = usage
                .and_then(|usage| usage.prompt_tokens_details.as_ref())
                .map(|details| details.cached_tokens),
            "the model answered"
        );

        body.choices
            .into_iter()
            .next()
            .map(|choice| choice.message.content)
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| ModelError::Failed("the reply carried no content".to_owned()))
    }

    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError> {
        // Timed to the first chunk, which is the wait the reader experiences;
        // the rest of a stream is bounded by how fast they read. No token
        // counts: this endpoint reports usage only when it is not streaming.
        let mut started = Some(Instant::now());
        let response = self.post(request, true).await?;

        // Server-sent events: `data: {json}` frames separated by blank lines,
        // ending at `data: [DONE]`. Decoded here rather than through an SSE
        // crate because the whole of the format this endpoint uses is those two
        // sentences.
        //
        // A channel and a task rather than a generator: the receiver *is* the
        // stream, so a client that hangs up drops it and the decoder below
        // notices immediately.
        let mut bytes = response.bytes_stream();
        let (sender, receiver) = tokio::sync::mpsc::channel(STREAM_BUFFER_FRAMES);

        tokio::spawn(async move {
            // Bytes, not a String: a network read can split a frame mid
            // character as easily as mid line, so nothing is decoded until a
            // whole line is in hand.
            let mut buffer: Vec<u8> = Vec::new();

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
                // provider can be the rest of the request's timeout away.
                let frame = tokio::select! {
                    frame = bytes.next() => frame,
                    () = sender.closed() => return,
                };

                // End of body without a `[DONE]`, which this endpoint sends
                // often enough that it is not itself a failure.
                let Some(frame) = frame else { break 'stream };

                let frame = match frame {
                    Ok(frame) => frame,
                    Err(error) => {
                        let broken =
                            ModelError::Failed(format!("the stream broke mid-answer: {error}"));
                        drop(sender.send(Err(broken)).await);
                        return;
                    }
                };

                buffer.extend_from_slice(&frame);

                while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
                    // Parsed from the slice and drained after: `parse_event`
                    // returns owned data, and `from_utf8_lossy` over valid UTF-8
                    // borrows — so the common case allocates nothing per line.
                    let event = parse_event(String::from_utf8_lossy(&buffer[..=newline]).trim());
                    buffer.drain(..=newline);

                    match event {
                        Event::Done => break 'stream,
                        Event::Failed(code) => {
                            // Sent without logging it here: `model_chunks` logs
                            // every `Err` it forwards, and this message carries
                            // the code, so a line here would be the same event
                            // recorded twice.
                            drop(sender.send(Err(mid_stream_failure(code.as_ref()))).await);
                            return;
                        }
                        Event::Text(text) if !text.is_empty() => {
                            if let Some(started) = started.take() {
                                tracing::info!(
                                    feature = "assistant",
                                    model = config::OPENROUTER_MODEL_ID,
                                    duration_ms = millis(started.elapsed()),
                                    "the model started answering"
                                );
                            }

                            // Whitespace is forwarded — it is the space between
                            // words — but it does not count as having answered,
                            // the same judgement `complete` makes with `trim`.
                            // A stream of nothing but blanks is silence with
                            // extra steps, and lands as an empty coach turn.
                            let said_something = !text.trim().is_empty();

                            if sender.send(Ok(text)).await.is_err() {
                                return;
                            }
                            answered = answered || said_something;
                        }
                        Event::Text(_) | Event::Ignored => {}
                    }
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

/// A failure the provider reported inside an open stream, named by its code.
///
/// Named rather than inline to keep the decoder's `Failed` arm a single line;
/// the code is all there is to report, for the reason [`StreamError`] gives.
fn mid_stream_failure(code: Option<&ErrorCode>) -> ModelError {
    ModelError::Failed(match code.and_then(ErrorCode::reported) {
        Some(code) => format!("the provider reported {code} mid-stream"),
        None => "the provider reported a failure mid-stream".to_owned(),
    })
}

/// One SSE line, reduced to what matters.
enum Event {
    /// Text to append to the explanation.
    Text(String),
    /// The provider said the stream is over.
    Done,
    /// The provider reported a failure inside a stream it had already opened —
    /// how a rate limit or an upstream outage arrives once the response is
    /// committed to a 200 and the headers are long gone.
    Failed(Option<ErrorCode>),
    /// A comment, a blank line, or a frame carrying no delta — every stream has
    /// several, and none of them is an error.
    Ignored,
}

fn parse_event(line: &str) -> Event {
    let Some(payload) = line.strip_prefix("data:") else {
        return Event::Ignored;
    };
    let payload = payload.trim();

    if payload == "[DONE]" {
        return Event::Done;
    }

    let Ok(frame) = serde_json::from_str::<StreamFrame>(payload) else {
        return Event::Ignored;
    };

    // Before the deltas: a frame carrying both is not a thing this endpoint
    // sends, and an error that fell through to `Ignored` is the failure mode
    // this arm exists to stop.
    if let Some(error) = frame.error {
        return Event::Failed(error.code);
    }

    frame
        .choices
        .into_iter()
        .next()
        .and_then(|choice| choice.delta.content)
        .map_or(Event::Ignored, Event::Text)
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'static str,
    max_tokens: i32,
    stream: bool,
    messages: Vec<Message<'a>>,
}

#[derive(Serialize)]
struct Message<'a> {
    role: &'static str,
    content: Vec<Part<'a>>,
}

#[derive(Serialize)]
struct Part<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    text: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    cache_control: Option<CacheControl>,
}

/// Marks the end of the prefix worth caching. Provider-specific and harmless
/// elsewhere: a route that does not understand it ignores the field.
#[derive(Serialize)]
struct CacheControl {
    #[serde(rename = "type")]
    kind: &'static str,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
    /// What the call cost, as the provider counted it. Optional because a route
    /// that does not report it is not a failed call.
    #[serde(default)]
    usage: Option<Usage>,
}

/// The token counts behind one call — the safe substitute for logging what was
/// asked and what came back.
#[derive(Deserialize)]
struct Usage {
    #[serde(default)]
    prompt_tokens: u32,
    #[serde(default)]
    completion_tokens: u32,
    #[serde(default)]
    prompt_tokens_details: Option<PromptTokensDetails>,
}

/// Carries `cached_tokens`: the part of the prefix the provider served from its
/// cache, and the only evidence that the `cache_control` marker above is worth
/// splitting the prompt for.
#[derive(Deserialize)]
struct PromptTokensDetails {
    #[serde(default)]
    cached_tokens: u32,
}

#[derive(Deserialize)]
struct Choice {
    message: ChoiceMessage,
}

#[derive(Deserialize)]
struct ChoiceMessage {
    #[serde(default)]
    content: String,
}

#[derive(Deserialize)]
struct StreamFrame {
    #[serde(default)]
    choices: Vec<StreamChoice>,
    /// Present only on a failure the provider reports mid-stream. Absent on
    /// every ordinary frame, which is why it is optional rather than a separate
    /// type tried in turn.
    #[serde(default)]
    error: Option<StreamError>,
}

/// A mid-stream failure, reduced to the one field that is safe to keep.
///
/// The sibling `message` is deliberately not read. It is the same hazard the
/// non-success branch of [`OpenRouterClient::post`] documents: a moderation
/// refusal quotes the input back, so the message is the person's own words and
/// must not reach a log or an error string.
#[derive(Deserialize)]
struct StreamError {
    #[serde(default)]
    code: Option<ErrorCode>,
}

/// The code on a mid-stream failure, in whichever shape it arrives.
///
/// Total by construction, and that is the point rather than tolerance for its
/// own sake: `serde` applies `default` only to an absent field, never to one
/// whose type surprised it, so a `code` this enum could refuse would fail the
/// whole frame's parse — and a frame that fails to parse reads as [`Event::Ignored`],
/// which is precisely the silent truncation the error arm exists to prevent.
#[derive(Deserialize)]
#[serde(untagged)]
enum ErrorCode {
    /// An HTTP-ish status, the common shape.
    Number(i64),
    /// A slug such as `rate_limit_exceeded`.
    Text(String),
    /// Any other shape, matched only so it cannot fail the frame. The value is
    /// deliberately discarded as it is read: nothing here may be reported,
    /// because a nested object could carry the provider's `message`.
    Unknown(serde::de::IgnoredAny),
}

impl ErrorCode {
    /// The code as it can safely be named, or `None` for a shape that might
    /// carry prose.
    fn reported(&self) -> Option<String> {
        match self {
            Self::Number(code) => Some(code.to_string()),
            Self::Text(code) => Some(code.clone()),
            Self::Unknown(_) => None,
        }
    }
}

#[derive(Deserialize)]
struct StreamChoice {
    /// Absent on the frames that carry a `finish_reason` and nothing else.
    /// Required, those frames fail to parse — and an error frame that also
    /// carries one would take the failure down with it.
    #[serde(default)]
    delta: Delta,
}

#[derive(Deserialize, Default)]
struct Delta {
    #[serde(default)]
    content: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three shapes every stream carries, and the one that must not be
    /// mistaken for text: `[DONE]` decodes as JSON never, and a frame with no
    /// delta arrives on every stream that reports usage at the end.
    #[test]
    fn only_content_deltas_become_text() {
        assert!(matches!(parse_event("data: [DONE]"), Event::Done));
        assert!(matches!(parse_event(""), Event::Ignored));
        assert!(matches!(parse_event(": keep-alive"), Event::Ignored));
        assert!(matches!(
            parse_event(r#"data: {"choices":[{"delta":{}}]}"#),
            Event::Ignored
        ));

        let Event::Text(text) =
            parse_event(r#"data: {"choices":[{"delta":{"content":"a long"}}]}"#)
        else {
            panic!("a content delta is text");
        };
        assert_eq!(text, "a long");
    }

    /// A malformed frame is skipped rather than failing the stream: the person
    /// is reading an explanation, and losing a sentence beats losing the rest
    /// of it.
    #[test]
    fn a_malformed_frame_is_skipped() {
        assert!(matches!(parse_event("data: {not json"), Event::Ignored));
    }

    /// How a rate limit or an upstream outage arrives once the response has
    /// already committed to a 200. Read as `Ignored` this decodes as a stream
    /// that simply stopped, which the caller cannot tell from a finished answer.
    ///
    /// Both frames carry a `message` and neither result does: the code is the
    /// only field [`StreamError`] takes, which is what keeps a moderation
    /// refusal's quoted input out of the error string.
    #[test]
    fn a_mid_stream_error_frame_fails_the_stream() {
        assert!(matches!(
            parse_event(r#"data: {"error":{"code":429,"message":"rate limited"}}"#),
            Event::Failed(Some(ErrorCode::Number(429)))
        ));
        assert!(matches!(
            parse_event(r#"data: {"error":{"message":"upstream is unwell"}}"#),
            Event::Failed(None)
        ));
    }

    /// Every one of these decodes as `Ignored` if the frame's types are drawn
    /// tighter than the provider actually sends — and `Ignored` is the silent
    /// truncation the error arm exists to prevent, so a shape surprise here
    /// costs the whole fix rather than one field.
    #[test]
    fn an_error_frame_survives_every_shape_its_code_arrives_in() {
        for frame in [
            r#"data: {"error":{"code":"rate_limit_exceeded"}}"#,
            r#"data: {"error":{"code":{"kind":"nested"}}}"#,
            r#"data: {"error":{"code":null}}"#,
            // An error alongside the finish_reason-only choice it arrives with.
            r#"data: {"error":{"code":429},"choices":[{"index":0,"finish_reason":"error"}]}"#,
        ] {
            assert!(
                matches!(parse_event(frame), Event::Failed(_)),
                "read as anything but a failure, this frame is silence: {frame}"
            );
        }
    }

    /// A slug is reported as itself; a shape that could nest the provider's
    /// `message` is reported as no code at all rather than rendered.
    #[test]
    fn only_a_scalar_code_is_named() {
        let reported = |frame: &str| match parse_event(frame) {
            Event::Failed(code) => mid_stream_failure(code.as_ref()).to_string(),
            _ => panic!("an error frame fails the stream: {frame}"),
        };

        assert!(
            reported(r#"data: {"error":{"code":"rate_limit_exceeded"}}"#)
                .contains("rate_limit_exceeded")
        );

        let nested = reported(r#"data: {"error":{"code":{"note":"flagged: my private words"}}}"#);
        assert!(!nested.contains("my private words"));
        assert!(
            nested.ends_with("the provider reported a failure mid-stream"),
            "a shape that could nest prose is named as no code at all: {nested}"
        );
    }

    /// The frames that carry a `finish_reason` and no `delta` at all. Required,
    /// `delta` makes these fail to parse, and every one of them then reads as a
    /// stream that simply stopped.
    #[test]
    fn a_frame_with_no_delta_is_merely_ignored() {
        assert!(matches!(
            parse_event(r#"data: {"choices":[{"index":0,"finish_reason":"stop"}]}"#),
            Event::Ignored
        ));
    }
}
