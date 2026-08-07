# Observability & Logging — Review Reference

You are reviewing the codebase for observability: the boundary principle, log level correctness, structured fields, coverage gaps, and sensitive data exposure.

Use finding ID prefix: **OBS**

`docs/observability.md` is the source of truth for the backend. Read it first — the checks below are its load-bearing rules made checkable, but the doc wins where they differ.

---

## 1. The Boundary Principle

**Log at boundaries, stay silent in between.**

Handlers log outcomes. `service.rs` and `repository.rs` say nothing — they communicate through typed errors, and the boundary that catches one decides whether it is worth a line. A repository that logs its own failure _and_ returns an error produces two records of one event, and the one with context is the one further out.

**What to check:**

- **`tracing::` calls in `service.rs` or `repository.rs`.** Each is a finding unless it is the deliberate exception below.
- **Log-and-propagate.** A function that logs an error and then returns `Err(…)` will be logged again wherever the error is handled. The inner log is the one to delete.
- **Chatty handlers.** The `TraceLayer` span already covers per-request accounting. A handler logging "handling request" on entry is duplicating it.

**The deliberate exception — log before converting.** Each feature's error enum logs server-side faults in its `From<…> for tonic::Status` impl, at the point of conversion. `crates/api/src/features/technique/errors.rs` is the pattern. The reason is specific: the client receives an opaque `internal` status, so a conversion that stays silent leaves the failure unreproducible from outside the process, and the sqlx error is deliberately not forwarded to the client because it can carry table and column names. Check every feature's `errors.rs` against this — a `From` impl that maps a server fault to `Status::internal` without logging the cause is the highest-value finding in this whole reference.

**Severity guide:**

- `From<…> for tonic::Status` mapping a server fault to `internal` with no log of the cause → Warning
- Logging in `service.rs` or `repository.rs` → Warning
- Log-then-propagate producing a double record → Suggestion

---

## 2. Log Level Correctness

Levels are keyed on a single question: _was this expected?_

| Level   | Means                                                    | Example                                                |
| :------ | :------------------------------------------------------- | :----------------------------------------------------- |
| `error` | Unexpected. Something is broken and a human should look. | A query failed against a schema that should support it |
| `warn`  | A handled failure mode. Degraded but understood.         | A dependency was unreachable and the fallback ran      |
| `info`  | A lifecycle milestone. Rare, and permanent.              | "connected to the database", "listening"               |
| `debug` | Detail for an investigation in progress                  | A connection retry attempt                             |
| `trace` | Per-request hot path                                     |                                                        |

**The test for `info`:** would you still want this line after a million requests? "listening" yes; "handled a request" no.

**What to check:**

- Per-request operations at `info`.
- A handled, understood degradation at `error` — the assistant falling back to its rule-based answer when the provider is unreachable is expected behaviour and belongs at `warn`. Every `error` line that fires during normal operation trains people to ignore errors.
- A genuine fault at `debug` or `info`, where it will be filtered out by the default `api=info,tower_http=info,warn`.
- Lifecycle events at `debug`.
- **Retry loops.** `docs/observability.md` fixes the shape: each attempt at `debug`, only the final failure at `warn` or `error`. Ten `warn` lines for a slow Postgres boot that resolved itself is the anti-pattern named in the doc.

**Severity guide:**

- Genuine fault logged below `warn`, where the default filter drops it → Warning
- Expected, handled degradation logged at `error` → Warning
- Every retry attempt logged at `warn`/`error` rather than the final failure only → Warning
- Minor level misassignment (info vs debug) → Suggestion

---

## 3. Structured Fields

**What to check:**

- **String interpolation instead of fields.** `tracing::error!("query for {} failed", id)` should be `tracing::error!(id = %id, "query failed")`. Values that are enums or IDs are recorded via Display: `goal = %goal`.
- **Field names.** These are fixed by `docs/observability.md` and exist so aggregation works: `error` (never `err`), `duration_ms` for elapsed time, `status` for HTTP status codes. Flag divergent names — `elapsed`, `err`, `time_ms`.
- **Message shape.** A short lowercase phrase, not a sentence: `"connected to the database"`, not `"Successfully connected to the database!"`.
- **`println!` / `eprintln!` / `dbg!` in production code.** All three are denied or warned by the workspace clippy lints (`dbg_macro` at deny), so an occurrence means an `#[allow]` is hiding it — check for that too.
- **Correlation ID.** `docs/observability.md` describes the pattern and states plainly that the helper does not exist yet because `/health` and `/about` are infallible, and that it should be written with the first fallible route. If a fallible HTTP route now exists without it, the deferral has expired — that is a finding, and a good one.

**Severity guide:**

- `dbg!` / `println!` / `eprintln!` in production code → Warning
- String interpolation carrying a value that should be a field → Warning
- A fallible HTTP route with no correlation id in its failure response → Warning
- Divergent field name vs the fixed set → Suggestion
- Message written as a capitalised sentence → Suggestion

---

## 4. Coverage Gaps

**What to check:**

- **Errors discarded at a boundary.** `let _ = …`, `if let Ok(x) = …` with no `else`, or `.unwrap_or_default()` on a fallible call, where nothing records that it failed. Silent failure is the most expensive kind to diagnose.
- **Decision points with no record.** Code branching on configuration or on a fallback path where nothing says which branch ran. The assistant's provider-versus-fallback choice and the circuit breaker's open/closed transitions are the current examples: a breaker that trips and recovers with no log leaves you unable to tell a degraded window from a quiet one.
- **Boundary operations that swallow.** An external call (the model provider) whose failure is converted to a fallback with no `warn`.
- **Missing cause.** A log carrying an error's message but not the source chain.

**Severity guide:**

- Error discarded with no log and no propagation → Warning
- External-dependency failure converted to a fallback with no `warn` → Warning
- State transition in a breaker or quota with no record → Suggestion
- Log carrying a message but not the error's source chain → Suggestion

---

## 5. Sensitive Data

Logs must never contain secrets, and this repo has two specific exposures worth checking by name.

**What to check:**

- **`OPENROUTER_API_KEY`.** The only secret the backend reads. Check that it never reaches a log, an error message, or a `Debug` derive on a struct that holds it. A `#[derive(Debug)]` on a config struct containing the key will print it the first time anyone logs that struct.
- **`DATABASE_URL`.** Carries credentials. Logging a connection string on a failed connect is the classic way this leaks — check `crates/migrate/src/main.rs` and any pool construction.
- **The user id.** `breathe-user-id` is an anonymous UUID rather than a name or an email, so it is fine to log and useful for correlation. Do not flag it as PII; do flag it appearing in a place that is shared or exported.
- **Prompt and completion text.** The assistant handles free text a person wrote about how they feel. Logging a prompt or a completion body — even at `debug` — puts that text in the log aggregator. Flag any body-level logging of model input or output; log token counts, durations, and outcomes instead.
- **sqlx errors reaching the client.** The inverse of the log-before-converting rule: the detail belongs in the log and must not be forwarded in the `tonic::Status` message, because it can carry table and column names.

**Severity guide:**

- API key, database URL, or any credential in a log or an error message → Critical
- sqlx error text forwarded to the client in a `Status` message → Warning
- Assistant prompt or completion body logged at any level → Warning
- Blanket request/response body logging with no field filtering → Warning

---

## 6. Format and Configuration

**What to check:**

- **Level configuration.** `RUST_LOG` overrides the filter; the default is `api=info,tower_http=info,warn`, chosen at boot in `crates/api/src/obs.rs` from `BREATHE_ENV`. Flag ad-hoc level gating anywhere else — a hand-rolled `if verbose` is a second configuration surface for something already configured.
- **Format selection.** JSON in production, human-readable in dev, decided once in `obs.rs`. Flag any second place that formats log output.
- **New environment variables.** `CLAUDE.md` §1.4 caps the backend at three: `BREATHE_ENV`, `DATABASE_URL`, and the optional `OPENROUTER_API_KEY`. A fourth read anywhere — including one that only affects logging — is a convention violation, because it is a value that can differ between a laptop and a deployment without anything noticing.
- **Metrics and tracing export.** `docs/observability.md` says neither exists yet, and that when metrics arrive they must be served on a **separate port** from the public listener so the scrape target is never exposed. If an exporter has appeared on the main listener, that is the finding.

**Severity guide:**

- A metrics or debug endpoint served on the public listener → Warning
- A fourth environment variable read by the backend → Warning
- Ad-hoc level gating or a second log-format decision outside `obs.rs` → Suggestion

---

## 7. Swift Logging

`docs/observability.md` covers the backend only, so the app's conventions are set by existing usage rather than by a document. That gap is itself worth reporting once if the Swift logging surface has grown — but review the code against what is already there:

- **`os.Logger`, one subsystem.** Every logger is constructed with subsystem `xyz.holmie.breathe` and a category naming the area (`wheel`, `audio`, `haptics`, `watch-link`). Flag a divergent subsystem string, a missing category, or a category that duplicates an existing one under a different name.
- **`print()` instead of a logger.** `print` output does not reach the unified log and vanishes outside a debugger session. Flag every occurrence in non-test code.
- **Privacy annotations.** `os_log` redacts interpolated dynamic strings by default and shows them as `<private>`. That is the right default for anything a person typed, and the wrong one for a technique slug or an error code you will need in a bug report — those want `privacy: .public`. Flag values marked `.public` that carry user-authored text, and diagnostic values left redacted where the log is then useless.
- **The boundary principle applies here too.** A repository that logs a decode failure _and_ throws leaves the model's catch block logging it again.
- **Errors swallowed in a `Task` or a `catch`.** A failure that only sets a UI flag with no log is invisible the moment the user dismisses the screen.

**Severity guide:**

- User-authored text logged with `privacy: .public` → Warning
- `print()` used for operational logging in non-test code → Warning
- `catch` block that updates UI state but never logs the cause → Warning
- Divergent subsystem, or a missing/duplicate category → Suggestion
- Diagnostic value left redacted, making the log unusable → Suggestion
