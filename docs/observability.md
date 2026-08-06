# Observability

## Guiding principle

**Log at boundaries, stay silent in between.**

Handlers log outcomes. `service.rs` and `repository.rs` say nothing — they communicate through typed errors, and the boundary that catches one decides whether it is worth a line. A repository that logs its own failure _and_ returns an error produces two records of one event, and the one with context is the one further out.

## Levels

Keyed on a single question: _was this expected?_

| Level   | Means                                                    | Example                                                |
| :------ | :------------------------------------------------------- | :----------------------------------------------------- |
| `error` | Unexpected. Something is broken and a human should look. | A query failed against a schema that should support it |
| `warn`  | A handled failure mode. Degraded but understood.         | A dependency was unreachable and the fallback ran      |
| `info`  | A lifecycle milestone. Rare, and permanent.              | "connected to the database", "listening"               |
| `debug` | Detail for an investigation in progress                  | A connection retry attempt                             |
| `trace` | Per-request hot path                                     |                                                        |

The test for `info`: would you still want this line after a million requests? "listening" yes; "handled a request" no — that is what the `TraceLayer` span is for.

## Field conventions

- `error`, never `err`.
- `duration_ms` for elapsed time, `status` for HTTP status codes.
- Values that are enums or IDs are recorded via Display: `goal = %goal`.
- The message is a short lowercase phrase, not a sentence: `"connected to the database"`.

## Named patterns

**Log before converting.** Each feature's error enum logs server-side faults in its `From<…> for tonic::Status` impl, at the point of conversion — `crates/api/src/features/technique/errors.rs` is the pattern. The client receives an opaque `internal` status, so a conversion that stays silent leaves the failure unreproducible from outside the process. The sqlx error is deliberately _not_ forwarded to the client — it can carry table and column names — and the log is where that detail belongs.

**Correlation ID.** When an HTTP handler returns a failure to a caller, mint a `cuid2`, log it alongside the cause, and return it in the body as `request_id`. A user-reported failure then resolves to one log line instead of a timestamp and a guess. No handler needs this yet — `/health` and `/about` are infallible — so the helper does not exist. Write it with the first fallible route rather than in advance.

**Level escalation.** A retry loop logs each attempt at `debug` and only the final failure at `warn` or `error`. No hand-written retry loop exists yet — `crates/migrate/src/main.rs` deliberately leans on sqlx's pool backoff instead — but the first one should follow this shape: a slow Postgres boot is normal, and ten `warn` lines for a situation that resolved itself trains people to ignore warnings.

## Format

JSON in production, human-readable in dev — chosen once at boot in `crates/api/src/obs.rs` from `BREATHE_ENV`. JSON is unreadable in a terminal and mandatory in a log aggregator, and `Environment` already knows which one is reading.

`RUST_LOG` overrides the filter; the default is `api=info,tower_http=info,warn`.

## Not yet present

No metrics, no tracing export, no error reporting. When metrics arrive they should be served on a **separate port** from the public listener, so the scrape target is never exposed through whatever fronts the API.
