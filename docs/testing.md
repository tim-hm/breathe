# Testing

> Write tests. Not too many. Mostly integration. — Guillermo Rauch

Each clause is doing work:

- **Write tests** — every non-obvious decision should be pinned by something that fails when it is undone.
- **Not too many** — a test has a permanent cost. It must be read, maintained, and understood before any change to the code it covers. Tests that restate the implementation charge that cost and return nothing.
- **Mostly integration** — the defects that reach users live at the seams: a proto enum that decodes to the wrong case, a query whose column type changed. Unit tests rarely span a seam.

## What not to test

- **Trivial CRUD.** A repository function that is one `SELECT` with no logic is verified by `sqlx::query_as!` at compile time — more thoroughly than a test could.
- **Type conversions with no rules.** A struct-to-struct copy where every field maps by name.
- **Thin wrappers.** If the function's whole body is a call to something else, the test asserts that Rust can call a function.
- **Framework behaviour.** axum routing, SwiftUI layout, and sqlx connection pooling are tested by their authors.

Ask instead: _if this broke, would anything else notice?_ If a compile error, a failing query, or a visibly broken screen would catch it first, the test is redundant.

## What is worth testing

The existing tests are the pattern:

| Test                                                | Guards                                                                                              |
| :-------------------------------------------------- | :-------------------------------------------------------------------------------------------------- |
| `carries_the_query_string_onto_the_maintenance_url` | Dropping the query string would silently change the maintenance connection's TLS mode               |
| `no_domain_goal_maps_to_unspecified`                | The proto zero value never escapes as a real enum case                                              |
| `slugs_are_unique`                                  | The seed upsert is keyed on `slug`; a duplicate would make array order decide which definition wins |
| `rejectsAnUnspecifiedGoal`                          | The Swift side of the same boundary — a newer server cannot put a technique in the wrong section    |

Every one covers a decision that is invisible in the code and expensive to rediscover.

## Conventions

**Rust** — inline `#[cfg(test)] mod tests` at the bottom of the file under test. Names are declarative sentences (`doubles_embedded_quotes`), and a `///` doc comment states the regression the test guards when that isn't obvious from the name. `clippy.toml` re-allows `unwrap`/`expect`/`panic` inside tests, where panicking _is_ the reporting mechanism.

**Swift** — Swift Testing, in each package's `Tests/`. `@Suite` and `@Test` carry prose descriptions, because those strings are what a failure prints.

Swift tests run on the **host**, not a simulator — every package declares a macOS platform alongside iOS specifically to make that possible. A decoding test should not need a booted device.

## Integration tests

`crates/api/tests/e2e/` drives the router `main.rs` serves, over a real Postgres. It is the only place the whole slice is exercised at once: rows in Postgres → repository → service → tonic → gRPC-Web framing → a decoded protobuf message.

**The disposable database.** Each test calls `TestDatabase::create("<name>")`, which derives its connection from `DATABASE_URL` by _replacing_ the database with `breathe_test_<name>`. The dev database is therefore unreachable from here by construction, not by convention — these tests drop wholesale. Creation drops any previous instance and re-migrates, so a failing test leaves its database behind for post-mortem inspection and the next run reclaims it. cargo-nextest runs each test in its own process, which is what makes one database per test the natural unit.

**Why `oneshot` rather than a listener.** The harness drives the assembled `Router` directly through `tower::ServiceExt::oneshot`. The layer stack under test — `GrpcWebLayer`, CORS, tonic's routes — _is_ the server's behaviour; binding a port would add hyper, a background task, and a shutdown race in order to test code we don't own.

**Why the real gRPC-Web framing.** `harness::call_grpc_web` writes the length-prefixed frame and parses the trailer frame by hand, exactly as the Swift client does. gRPC-Web reports call outcomes in trailers, so a _failed_ call still returns HTTP 200 — a harness that called `service::list_techniques` directly could never catch an error that fails to reach the client.

The four tests and what they pin:

| Test                                                         | Guards                                                                                                              |
| :----------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| `the_seeded_catalogue_arrives_over_grpc_web`                 | The bootstrap's acceptance criterion, minus the simulator                                                           |
| `phase_order_follows_ordinal_not_insertion_order`            | The service groups phases through a `HashMap`; the fixture inserts a cycle out of order so ignoring `ordinal` fails |
| `a_phaseless_technique_fails_the_call_rather_than_vanishing` | A corrupt row surfaces as a non-zero `grpc-status`, not a quietly shortened list                                    |
| `health_answers_without_a_reachable_database`                | `/health` is liveness-only; its pool points at a dead port, so answering at all proves it issued no query           |

Each was verified by breaking the code it covers and confirming it fails.

## Running them

```bash
mise run test        # everything
mise run test:rs     # Rust unit tests — no database, no network
mise run test:e2e    # integration tests; starts Postgres if it isn't running
mise run test:swift  # Swift Testing, on the host
```

`test:rs` and `test:e2e` are both part of `mise run check`, which is why the gate needs Docker. `test:swift` is not, because it needs the Xcode toolchain — run it when you touch `ios/`. In Xcode, ⌘U runs the same suites — the scheme's Test action is wired to the package's test target.

## What is not covered yet

There are no UI tests, and nothing exercises the Swift client against a live server — `TechniqueRepository` is tested against constructed proto values, not a socket. Closing that gap means a booted simulator and a running backend in the same job, which is a CI problem before it is a testing one. Until then, the contract between the two is held by `check:generated` (the committed Swift matches `proto/`) and by the decoding tests on either side of the boundary.
