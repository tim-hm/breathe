# Testing

> Write tests. Not too many. Mostly integration.
> — Guillermo Rauch

Each clause is doing work:

- **Write tests** — every non-obvious decision should be pinned by something that fails when it is undone.
- **Not too many** — a test has a permanent cost. It must be read, maintained, and understood before any change to the code it covers. Tests that restate the implementation charge that cost and return nothing.
- **Mostly integration** — the defects that reach users live at the seams: a proto enum that decodes to the wrong case, a query whose column type changed. Unit tests rarely span a seam.

## What not to test

- **Trivial CRUD.** A repository function that is one `SELECT` with no logic is verified by `sqlx::query_as!` at compile time — more thoroughly than a test could.
- **Type conversions with no rules.** A struct-to-struct copy where every field maps by name.
- **Thin wrappers.** If the function's whole body is a call to something else, the test asserts that Rust can call a function.
- **Framework behaviour.** axum routing, SwiftUI layout, and sqlx connection pooling are tested by their authors.

Ask instead: *if this broke, would anything else notice?* If a compile error, a failing query, or a visibly broken screen would catch it first, the test is redundant.

## What is worth testing

The existing tests are the pattern:

| Test | Guards |
| :-- | :-- |
| `carries_the_query_string_onto_the_maintenance_url` | A regression: dropping the query string silently changed one connection's TLS mode |
| `no_domain_goal_maps_to_unspecified` | The proto zero value never escapes as a real enum case |
| `slugs_are_unique` | The seed upsert is keyed on `slug`; a duplicate would make array order decide which definition wins |
| `rejectsAnUnspecifiedGoal` | The Swift side of the same boundary — a newer server cannot put a technique in the wrong section |

Every one covers a decision that is invisible in the code and expensive to rediscover.

## Conventions

**Rust** — inline `#[cfg(test)] mod tests` at the bottom of the file under test. Names are declarative sentences (`rejects_a_url_naming_no_database`), and a `///` doc comment states the regression the test guards when that isn't obvious from the name. `clippy.toml` re-allows `unwrap`/`expect`/`panic` inside tests, where panicking *is* the reporting mechanism.

**Swift** — Swift Testing, in each package's `Tests/`. `@Suite` and `@Test` carry prose descriptions, because those strings are what a failure prints.

Swift tests run on the **host**, not a simulator — every package declares a macOS platform alongside iOS specifically to make that possible. A decoding test should not need a booted device.

## Running them

```bash
mise run test        # everything
mise run test:rs     # cargo-nextest across the workspace
mise run test:swift  # Swift Testing, on the host
```

`test:rs` is part of `mise run check`. `test:swift` is not, because it needs the Xcode toolchain — run it when you touch `ios/`.

## What is not covered yet

There are no integration tests against a live server, and no UI tests. The vertical slice is verified by hand (`grpcurl`, then the app). The first feature with real branching behaviour should bring a `crates/api/tests/` harness with it: an in-process server on a random port against a **disposable** database — never the dev one, since such tests delete rows wholesale.
