# Observability

## Guiding principle

**Log at boundaries, stay silent in between.**

A line belongs where the error stops. Code that returns a typed error says nothing about it — the boundary that catches one has the context and decides whether it is worth a line, and a repository that logs its own failure _and_ returns it produces two records of one event. In practice that means handlers and the `From<…> for Status` impls speak while `service.rs` and `repository.rs` stay quiet, with one exception the named patterns below make explicit: a layer that swallows an error rather than returning it _is_ the boundary for that error.

## Levels

Keyed on a single question: _was this expected?_

| Level   | Means                                                    | Example                                                |
| :------ | :------------------------------------------------------- | :----------------------------------------------------- |
| `error` | Unexpected. Something is broken and a human should look. | A query failed against a schema that should support it |
| `warn`  | A handled failure mode. Degraded but understood.         | A dependency was unreachable and the fallback ran      |
| `info`  | A lifecycle milestone. Rare, and permanent.              | "connected to the database", "listening"               |
| `debug` | Detail for an investigation in progress                  | A connection retry attempt                             |
| `trace` | Per-request hot path                                     |                                                        |

The test for `info`: would you still want this line after a million requests? "listening" yes; a handler announcing that it is about to do its job, no.

One record per request is the exception, and it earns the level because it is the only thing that answers "what was this process doing at 14:03". It is emitted once, on the way out, by the `TraceLayer` in `crates/api/src/obs.rs` — carrying `status`, `grpc_status` and `duration_ms` against a span holding `method`, `path` and `user_id`. Everything else inherits that span, which is what makes a feature's one-line `error` resolvable to a caller and an RPC. Note that a span emits nothing by itself: the layer was installed for a long time at a level the default filter dropped, and the process was silent per request the whole while.

## Field conventions

- `error`, never `err`.
- `duration_ms` for elapsed time, `status` for HTTP status codes.
- Values that are enums or IDs are recorded via Display: `goal = %goal`.
- The message is a short lowercase phrase, not a sentence: `"connected to the database"`.

## Named patterns

**Log before converting.** Each feature's error enum logs server-side faults in its `From<…> for tonic::Status` impl, at the point of conversion — `crates/api/src/features/technique/errors.rs` is the pattern. The client receives an opaque `internal` status, so a conversion that stays silent leaves the failure unreproducible from outside the process. The sqlx error is deliberately _not_ forwarded to the client — it can carry table and column names — and the log is where that detail belongs.

**Log what you swallow.** `crates/api/src/features/assistant/service.rs` is the service allowed to speak, and the reason is that its errors terminate there: a model call that fails, a reply naming no technique in the catalogue, and a spent daily allowance all end in the rule-based fallback, and the RPC returns a perfectly good answer. Nothing downstream is ever told, so deleting those lines makes a provider outage invisible from outside the process — the same failure log-before-converting prevents, reached from the other direction.

**Correlation ID.** When an HTTP handler returns a failure to a caller, mint a `cuid2`, log it alongside the cause, and return it in the body as `request_id`. A user-reported failure then resolves to one log line instead of a timestamp and a guess. No handler needs this yet — `/health` and `/about` are infallible — so the helper does not exist. Write it with the first fallible route rather than in advance.

**Level escalation.** A retry loop logs each attempt at `debug` and only the final failure at `warn` or `error`. No hand-written retry loop exists yet — `crates/migrate/src/main.rs` deliberately leans on sqlx's pool backoff instead — but the first one should follow this shape: a slow Postgres boot is normal, and ten `warn` lines for a situation that resolved itself trains people to ignore warnings.

## Format

JSON in production, human-readable in dev — chosen once at boot in `crates/api/src/obs.rs` from `BREATHE_ENV`. JSON is unreadable in a terminal and mandatory in a log aggregator, and `Environment` already knows which one is reading.

`RUST_LOG` overrides the filter; the default is `api=info,tower_http=info,warn`.

## The Swift client

The principle above carries over unchanged. `os.Logger` does not: four of its properties decide whether a line survives to be read at all, and each has caught this codebase out.

**One subsystem: `xyz.holmie.breathe`,** taken from a single constant in `BreatheKit` rather than a literal or a `Bundle.main.bundleIdentifier` lookup. `Bundle.main` is the _host process_, so the same `BreatheKit` file files under one subsystem when the phone loads it and another when the watch does — and `log stream --subsystem xyz.holmie.breathe` then silently omits the watch, the target whose failures are hardest to reproduce. A subsystem that varies by host is not a subsystem.

**A category names the channel, not the file.** Both ends of the phone↔watch handoff take `watch-link`, so correlating a dropped identity means one name rather than two. The set today:

| Category           | Covers                                                                   |
| :----------------- | :----------------------------------------------------------------------- |
| `identity`         | The anonymous id — Keychain reads and writes, and the watch adopting one |
| `profile`          | Onboarding's answers syncing out and restoring back                      |
| `session-store`    | The local session and tombstone files                                    |
| `bolt-store`       | The local controlled-pause file                                          |
| `journey-sync`     | Sessions, tombstones, and pause scores draining to the server            |
| `catalogue-cache`  | The offline catalogue's reads and writes                                 |
| `leaderboard`      | The one screen that needs a connection, and what it does without one     |
| `assistant`        | Guidance and explanations, including a stream the provider cut short     |
| `subscription`     | StoreKit purchases and restores, and the entitlement the server stores   |
| `watch-link`       | The handoff, from both ends                                              |
| `haptics`, `audio` | The session's cue engines                                                |
| `extended-runtime` | The watch's grant to keep running with the wrist down                    |

**Levels answer the same question — _was this expected?_** — against a second constraint the backend does not have: `notice` and above are written to the on-disk log store, which is what a sysdiagnose collects and which has a fixed size budget.

| Level    | Means                                                  | Example                                               |
| :------- | :----------------------------------------------------- | :---------------------------------------------------- |
| `error`  | Broken, and nothing recovers it                        | The Keychain refused to store the anonymous identity  |
| `notice` | A handled degradation. Offline-first behaviour working | A sync deferred, or a cache that could not be written |
| `debug`  | Detail for an investigation in progress                | A per-cue scheduling decision                         |

So anything per-frame, per-detent, or per-cue is `debug`, whatever it would otherwise deserve: a persisted line on a drag gesture evicts the sync and identity failures that were the reason to keep a log store at all.

**Framework error text is public; the person's words never are.** Interpolation defaults to `.private` for `String`, and `error.localizedDescription` is a `String` — so a line reads `<private>` everywhere except a live debugger, which is the one place it was not needed. Framework-authored text carries no user data, so it takes the annotation explicitly:

```swift
logger.notice("session sync deferred: \(error.localizedDescription, privacy: .public)")
```

The display name and the intent note never do. They are the person's own words, and unlike the backend's anonymous `user_id` there is nothing anonymous about them.

## Not yet present

No metrics, no tracing export, no error reporting. When metrics arrive they should be served on a **separate port** from the public listener, so the scrape target is never exposed through whatever fronts the API.
