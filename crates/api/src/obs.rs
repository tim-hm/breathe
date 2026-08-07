//! Telemetry: the subscriber chosen at boot, and the one record every request
//! leaves behind.
//!
//! Logging convention (docs/observability.md): log at boundaries, stay silent in
//! between. Handlers log outcomes; services and repositories communicate through
//! typed errors and say nothing. The record that a request happened at all
//! belongs here rather than to any handler, which is why none writes one.

use std::time::Duration;

use axum::http::{HeaderMap, Request, Response};
use tower_http::classify::{ServerErrorsAsFailures, SharedClassifier};
use tower_http::trace::{MakeSpan, OnResponse, TraceLayer};
use tracing::{Span, field};
use tracing_subscriber::EnvFilter;
use uuid::Uuid;

/// The filter every process runs under unless `RUST_LOG` overrides it.
///
/// A constant rather than a literal because the level it grants `api` is what
/// decides whether a deployed process is observable at all: a span or an event
/// below the filter is never created, so anything that would have attached to
/// the request span — the caller, the RPC, the `errors.rs` conversions — is
/// lost before it exists. The tests below run against this exact string for
/// that reason.
pub const DEFAULT_FILTER: &str = "api=info,tower_http=info,warn";

/// Where gRPC puts the real outcome, HTTP 200 notwithstanding.
const GRPC_STATUS: &str = "grpc-status";

/// Installs the global subscriber.
///
/// The formatter is chosen once, at boot, from the environment: JSON is
/// unreadable in a terminal and mandatory in a log aggregator, and only one of
/// those is ever reading.
pub fn init(json: bool) {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));

    let builder = tracing_subscriber::fmt().with_env_filter(filter);

    if json {
        builder.json().init();
    } else {
        builder.init();
    }
}

/// The layer that produces the process's only per-request output.
///
/// Every callback `TraceLayer` ships is replaced, and each replacement closes a
/// way the stock layer was silent or wrong on a listener serving two protocols:
///
/// - tower-http's `DEFAULT_MESSAGE_LEVEL` is `DEBUG`, which [`DEFAULT_FILTER`]
///   drops — and because a span below the filter is never entered, the defaults
///   removed the span as well as the events.
/// - The classification `new_for_http` installs reads the HTTP status, and a
///   failed RPC is HTTP 200 with its code in a header. Rather than teach a
///   classifier to read that header, [`RequestComplete`] records the code as a
///   field and `on_failure` is disabled — one event per request, whatever
///   happened, which is also why the classifier the constructor insists on is
///   never consulted.
pub fn trace_layer() -> TraceLayer<
    SharedClassifier<ServerErrorsAsFailures>,
    RequestSpan,
    (),
    RequestComplete,
    (),
    (),
    (),
> {
    TraceLayer::new_for_http()
        .make_span_with(RequestSpan)
        .on_request(())
        .on_response(RequestComplete)
        .on_body_chunk(())
        .on_eos(())
        .on_failure(())
}

/// The span every request runs inside, and the reason the `errors.rs`
/// conversions need no context of their own.
///
/// `path` is the gRPC method for an RPC (`/ond.v1.TechniqueService/…`) and
/// the route for the JSON surface, so one field answers "which operation" for
/// both protocols. `user_id` is declared empty here and filled in by
/// [`record_user_id`] once `identity::resolve` knows who is calling.
#[derive(Clone, Copy, Debug)]
pub struct RequestSpan;

impl<B> MakeSpan<B> for RequestSpan {
    fn make_span(&mut self, request: &Request<B>) -> Span {
        tracing::info_span!(
            "request",
            method = %request.method(),
            path = %request.uri().path(),
            user_id = field::Empty,
        )
    }
}

/// The one line a completed request writes.
///
/// `info` for every outcome, including a failed one. A fault is already logged
/// at `error`, with the cause, by the feature's `From<…> for Status` — and this
/// line cannot restate that without making one incident two records and
/// doubling every error count taken off the log. What it adds instead is
/// `grpc_status`, so failures stay countable from the access record without a
/// level standing in for a field.
///
/// `duration_ms` measures to the response head rather than the last body byte,
/// because that is the point at which tower-http hands over the latency. For
/// `ExplainTechnique`, the one server-streaming RPC, that makes it
/// time-to-first-token.
#[derive(Clone, Copy, Debug)]
pub struct RequestComplete;

impl<B> OnResponse<B> for RequestComplete {
    fn on_response(self, response: &Response<B>, latency: Duration, _span: &Span) {
        // Narrowed from the `u128` `as_millis` returns, because the JSON
        // formatter writes a `u128` as a *string* — a latency no aggregator can
        // aggregate. Nothing saturates: the ceiling is 584 million years.
        let duration_ms = u64::try_from(latency.as_millis()).unwrap_or(u64::MAX);

        tracing::info!(
            status = response.status().as_u16(),
            grpc_status = grpc_status(response.headers()),
            duration_ms,
            "request completed"
        );
    }
}

/// Records the caller on the in-flight request span.
///
/// Declared by [`RequestSpan`] and filled in here so the two halves sit in one
/// edit radius: `Span::record` against a field the span never declared is a
/// silent no-op, and a caller in another module could not see that it had
/// become one. Everything the request goes on to log — the completion line and
/// each feature's `From<…> for Status` conversion — inherits the field without
/// naming it.
pub fn record_user_id(user_id: Uuid) {
    Span::current().record("user_id", field::display(user_id));
}

/// Reads the gRPC outcome a response carries, if it carries one.
///
/// The headers rather than the trailers, on purpose twice over: tonic answers a
/// failed RPC with a trailers-only response, and `GrpcWebLayer` — which this
/// layer wraps — has already folded any genuine trailers into the body, where
/// no `ClassifyEos` could reach them. The consequence is that a stream failing
/// after its first message is invisible to this layer; the feature that
/// produced the failure logs it, inside this request's span.
///
/// The number rather than a `tonic::Code`, because the field exists to be
/// counted and grouped by; a reader wanting the name of 13 has the table.
fn grpc_status(headers: &HeaderMap) -> Option<i32> {
    headers.get(GRPC_STATUS)?.to_str().ok()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use std::convert::Infallible;
    use std::io;
    use std::sync::{Arc, Mutex};

    use axum::body::Body;
    use axum::http::{HeaderValue, StatusCode};
    use tower::{ServiceBuilder, ServiceExt};
    use tracing_subscriber::fmt::MakeWriter;

    use super::*;

    /// Collects formatted output so a test can assert on what a deployed
    /// process would have written, rather than on the shape of the layer.
    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Captured {
        fn contents(&self) -> String {
            let bytes = self.0.lock().unwrap().clone();
            String::from_utf8(bytes).unwrap()
        }
    }

    impl io::Write for Captured {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for Captured {
        type Writer = Self;

        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    /// Drives one request through [`trace_layer`] under [`DEFAULT_FILTER`] and
    /// returns what was logged.
    ///
    /// The filter is the production one rather than `TRACE` because the defect
    /// this layer exists to fix was an interaction between the callbacks' level
    /// and the filter — a test that lowered the filter would have passed
    /// against the broken code.
    async fn log_of(
        status: StatusCode,
        grpc_status: Option<&'static str>,
        user_id: Option<Uuid>,
    ) -> String {
        let captured = Captured::default();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::new(DEFAULT_FILTER))
            .with_writer(captured.clone())
            .with_ansi(false)
            .finish();

        let service = ServiceBuilder::new()
            .layer(trace_layer())
            .service(tower::service_fn(
                move |_request: Request<Body>| async move {
                    if let Some(user_id) = user_id {
                        record_user_id(user_id);
                    }

                    let mut response = Response::new(Body::empty());
                    *response.status_mut() = status;
                    if let Some(code) = grpc_status {
                        response
                            .headers_mut()
                            .insert(GRPC_STATUS, HeaderValue::from_static(code));
                    }
                    Ok::<_, Infallible>(response)
                },
            ));

        let request = Request::post("/ond.v1.JourneyService/RecordSessions")
            .body(Body::empty())
            .unwrap();

        let _guard = tracing::subscriber::set_default(subscriber);
        service.oneshot(request).await.unwrap();

        captured.contents()
    }

    /// The headline of [OBS-001] and [OBS-002] together: one failing RPC, and
    /// every field somebody answering "which user, which call, at what time"
    /// needs is on the line.
    #[tokio::test]
    async fn a_failed_rpc_names_its_caller_and_its_operation() {
        let user_id = Uuid::from_u128(0x0192_38ab_cdef_4567_89ab_cdef_0123_4567);
        let logged = log_of(StatusCode::OK, Some("13"), Some(user_id)).await;

        assert!(logged.contains("method=POST"), "{logged}");
        assert!(
            logged.contains("path=/ond.v1.JourneyService/RecordSessions"),
            "{logged}"
        );
        assert!(logged.contains(&user_id.to_string()), "{logged}");
        assert!(logged.contains("status=200"), "{logged}");
        assert!(logged.contains("grpc_status=13"), "{logged}");
        assert!(logged.contains("duration_ms="), "{logged}");
    }

    /// Whatever happened, exactly one record — never none, which was the
    /// defect, and never two, which is what a level standing in for a field
    /// would have cost once the feature had already logged the cause. A
    /// gRPC-Web *success* carries no `grpc-status` header at all, the trailer
    /// being inside the body, so the no-status-at-200 case is the ordinary one
    /// rather than an edge.
    #[tokio::test]
    async fn every_outcome_leaves_exactly_one_record() {
        let cases = [
            (StatusCode::OK, None),
            (StatusCode::OK, Some("0")),
            (StatusCode::OK, Some("13")),
            (StatusCode::NOT_FOUND, None),
            (StatusCode::INTERNAL_SERVER_ERROR, None),
        ];

        for (status, grpc_status) in cases {
            let logged = log_of(status, grpc_status, None).await;

            assert_eq!(logged.lines().count(), 1, "{logged}");
            assert!(logged.contains(" INFO"), "{logged}");
            assert!(
                logged.contains(&format!("status={}", status.as_u16())),
                "{logged}"
            );
            assert!(logged.contains("duration_ms="), "{logged}");

            if let Some(code) = grpc_status {
                assert!(logged.contains(&format!("grpc_status={code}")), "{logged}");
            }
        }
    }
}
