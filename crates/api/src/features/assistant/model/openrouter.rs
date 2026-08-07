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

use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt as _;

use super::{ModelClient, ModelError, ModelRequest, ModelStream};
use crate::config;

/// Bounds a single call. Generous enough for a long explanation on a slow day
/// and short enough that a hung provider does not hold a connection — and, more
/// to the point, does not hold the person's screen: the breaker needs failures
/// to arrive to be able to trip on them.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);

/// How far the caller's own text is echoed into a log line when a call fails.
///
/// Enough to recognise which prompt broke, short enough that an intent note
/// somebody typed does not end up whole in a log aggregator.
const ERROR_EXCERPT_CHARS: usize = 200;

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
    /// Returns `None` when the key's `reqwest::Client` cannot be built, which
    /// in practice means the TLS backend failed to initialise — a boot-time
    /// fault, and one the caller answers by running without an assistant rather
    /// than refusing to serve the rest of the API.
    pub fn new(api_key: &str) -> Option<Self> {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .ok()?;

        Some(Self {
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
        let body = ChatRequest {
            model: config::OPENROUTER_MODEL_ID,
            max_tokens: request.max_tokens,
            stream: streaming,
            messages: vec![
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
            ],
        };

        let response = self
            .http
            .post(&self.endpoint)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|error| {
                ModelError::Failed(format!("the request did not complete: {error}"))
            })?;

        let status = response.status();
        if !status.is_success() {
            // The body is read for the log, not for the caller: a provider
            // error can quote the prompt back, and the prompt carries the
            // person's own words.
            let detail = response.text().await.unwrap_or_default();
            tracing::warn!(
                feature = "assistant",
                %status,
                detail = %excerpt(&detail),
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
        let response = self.post(request, false).await?;

        let body: ChatResponse = response
            .json()
            .await
            .map_err(|error| ModelError::Failed(format!("the reply did not decode: {error}")))?;

        body.choices
            .into_iter()
            .next()
            .map(|choice| choice.message.content)
            .filter(|content| !content.trim().is_empty())
            .ok_or_else(|| ModelError::Failed("the reply carried no content".to_owned()))
    }

    async fn stream(&self, request: &ModelRequest) -> Result<ModelStream, ModelError> {
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

            loop {
                // Races the next frame against the client going away. Without
                // the second arm, a reader who closed the screen mid-answer is
                // only noticed on the following `send`, which for a slow
                // provider can be the rest of the request's timeout away.
                let frame = tokio::select! {
                    frame = bytes.next() => frame,
                    () = sender.closed() => return,
                };

                let Some(frame) = frame else {
                    return;
                };

                let Ok(frame) = frame else {
                    let broken = ModelError::Failed("the stream broke mid-answer".to_owned());
                    drop(sender.send(Err(broken)).await);
                    return;
                };

                buffer.extend_from_slice(&frame);

                while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
                    // Parsed from the slice and drained after: `parse_event`
                    // returns owned data, and `from_utf8_lossy` over valid UTF-8
                    // borrows — so the common case allocates nothing per line.
                    let event = parse_event(String::from_utf8_lossy(&buffer[..=newline]).trim());
                    buffer.drain(..=newline);

                    match event {
                        Event::Done => return,
                        Event::Text(text) if !text.is_empty() => {
                            if sender.send(Ok(text)).await.is_err() {
                                return;
                            }
                        }
                        Event::Text(_) | Event::Ignored => {}
                    }
                }
            }
        });

        Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(
            receiver,
        )))
    }
}

/// One SSE line, reduced to what matters.
enum Event {
    /// Text to append to the explanation.
    Text(String),
    /// The provider said the stream is over.
    Done,
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

    frame
        .choices
        .into_iter()
        .next()
        .and_then(|choice| choice.delta.content)
        .map_or(Event::Ignored, Event::Text)
}

/// Trims text for a log line, counting characters so a multi-byte excerpt is
/// never cut mid-character.
fn excerpt(text: &str) -> String {
    text.chars().take(ERROR_EXCERPT_CHARS).collect()
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
}

#[derive(Deserialize)]
struct StreamChoice {
    delta: Delta,
}

#[derive(Deserialize)]
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
}
