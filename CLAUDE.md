# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. Global workflow and core principles are in `~/.claude/CLAUDE.md`.

## 1. Guiding Principles

1. **Types**: Code must be strongly typed. Avoid `any`, `as`, force-unwraps, and other type-safety escape hatches. Inferred types are acceptable within function bodies; function signatures and complex types are explicit.
2. **Documentation**: The doc comment carries the explanation; inline comments must earn their line.
   - **Explain on the item.** A `///` / `//!` block (Rust) or `///` block (Swift) documents every public function (and its parameters), every enum (and its values), and every non-obvious exported type. Put the _why_ there: the constraint, the invariant, the ordering hazard, the external quirk, the regression the code guards against.
   - **Three inline comments earn their line**: (a) a step marker segmenting a genuinely long body, sitting directly on the code it describes; (b) a fact the reader cannot deduce from the code, anchored to one specific statement — `// Postgres 18 moved the data directory` on the exact volume mount; (c) a note that the code is deliberately unusual or suboptimal-looking, so the next reader doesn't "fix" it. A body needing a signpost every few lines wants a named function instead.
   - **Delete restatements.** If the code says it as well or better, the comment goes: no `// Sort by sort_order` above an `ORDER BY sort_order`.
   - **Never comment on distant code.** A comment is only trustworthy inside the edit radius of the code it describes. Section banners (`// ── Types ──`, `// ==== Helpers ====`) assert a file layout that nothing enforces — an editor working 200 lines below never has them in context, so they rot silently. Banned.
   - **Always keep, verbatim**: `SAFETY:`, `TODO`/`FIXME`, and tool pragmas (`#[allow(...)]` justifications, `swiftlint:disable`). Deleting one breaks the build or silences a real warning.
   - **Never commit** commented-out code, or comments narrating the edit you just made ("Added in…", "Changed from…"). Git already holds that history.
   - Use an active voice. Use camel case for abbreviations in identifiers and type names: `Did`, not `DID`; `TechniqueId`, not `TechniqueID`. Prose keeps the natural form — "the technique's ID".
   - Assume the reader has a working knowledge of the codebase.
3. **Ergonomics and DX**: Prioritise intuitive API design and developer experience.
4. **Minimal Environment Footprint**: Environment variables are for secrets and essential boot-time context only. The backend reads exactly three — `OND_ENV`, `DATABASE_URL`, and the optional `OPENROUTER_API_KEY` (a secret, which is what the principle admits; absent, the assistant answers from its rule-based fallback). Everything else is derived in `crates/api/src/config.rs` — including which provider and which model the assistant calls, because a model id that could differ between a laptop and a deployment is exactly the drift this rule exists to prevent. Every new variable is a value that can differ between the two without anything noticing.
5. **Derivation by Convention**: Ports, log format, and CORS policy derive from `OND_ENV`. Prefer deriving over configuring.
6. **Code Structure**: Follow [docs/code-structure.md](docs/code-structure.md) — feature-first (not layer-first), three-tier escalation, and the naming conventions defined there.

## 2. Architecture

A Cargo workspace (`crates/`) and two native SwiftUI apps (`ios/`) sharing one Protobuf contract (`proto/`). PostgreSQL is the only datastore. Both clients talk **gRPC-Web** to a tonic backend; a small JSON surface (`/health`, `/about`) exists for `curl`.

```text
proto/          the contract — single source of truth for both languages
crates/api      axum (JSON) + tonic (gRPC-Web) on one port
crates/migrate  schema migrations + the seeded technique catalogue
ios/            two app targets — Ond (iOS) and OndWatch (watchOS) —
                over one local SwiftPM package, OndCore
web/            the marketing one-pager; static at serve time, but its
                technique figures are generated from the app's own geometry
infra/          OpenTofu for the one box the whole thing deploys onto
catalogue.json  the seeded catalogue, exported from crates/migrate so the
                drawings can be derived from the numbers the database holds
```

All önd ports live in **18100–18199** (API 18100, Postgres 18101, `web/` preview 18102). See [docs/contributing.md](docs/contributing.md) for why the block starts there.

| Pattern        | One-liner                                                                              | Details                                          |
| :------------- | :------------------------------------------------------------------------------------- | :----------------------------------------------- |
| Transport      | One `.proto` generates Rust server stubs and the Swift client; gRPC-Web over HTTP POST | [docs/transport.md](docs/transport.md)           |
| Code structure | Feature-first, three-tier escalation, no junk drawers                                  | [docs/code-structure.md](docs/code-structure.md) |
| Testing        | Write tests. Not too many. Mostly integration.                                         | [docs/testing.md](docs/testing.md)               |
| Observability  | Log at boundaries, stay silent in between                                              | [docs/observability.md](docs/observability.md)   |
| Setup & ports  | First run, port table, Xcode prerequisites                                             | [docs/contributing.md](docs/contributing.md)     |
| Deployment     | One box: OpenTofu provisions it, `mise run deploy` ships to it, Caddy fronts it        | [docs/deployment.md](docs/deployment.md)         |

### Where code lives

- **Router assembly** — `crates/api/src/lib.rs`. `main.rs` is process startup only; everything else is library so `tests/e2e/` drives the same stack a deployment serves.
- **AppState** — `crates/api/src/state.rs`, shared as `Arc<AppState>`.
- **Features** — `crates/api/src/features/<name>/` with `handlers/`, `service.rs`, `repository.rs`, `types.rs`, `errors.rs`.
- **gRPC registration** — `crates/api/src/grpc.rs`. **HTTP routes** — `crates/api/src/http/mod.rs`. Both are single aggregation points.
- **Generated protobuf** — Rust into `OUT_DIR` via `crates/api/build.rs`, re-exported through `crates/api/src/proto.rs`; Swift committed under `ios/Packages/OndCore/Sources/OndAPI/Generated/`.
- **Domain models (Swift)** — the `OndKit` target in `ios/Packages/OndCore/`. Only it touches generated protobuf types; `OndAPI` is not a package product, so neither app target can import one.
- **App targets (Swift)** — `ios/Ond/` (iOS) and `ios/OndWatch/` (watchOS), each with its own composition root over the same three products. What they share and what they deliberately duplicate is in [docs/code-structure.md](docs/code-structure.md).

## 3. Development

**Mise-first rule**: run every repo operation through `mise run <task>` — never raw `cargo clippy/test/sqlx`, `buf generate`, `xcodebuild`, or `swiftlint`. The tasks encode the env (`SQLX_OFFLINE`, `DATABASE_URL`, `CARGO_TARGET_DIR`) those commands need to behave identically here, in a fresh clone, and in CI. `mise tasks` lists everything; if an operation has no task, add one rather than bypassing.

This rule has teeth: a shell that has visited the sibling `connect` repo exports a `DATABASE_URL` pointing at _its_ database on port 15432. Running `cargo run -p migrate` directly from such a shell targets the wrong cluster. `mise run migrate` cannot.

**Toolkit-first rule**: helper tooling is a mise task or a subcommand of a future `toolkit` crate — never a loose bash/python script. `scripts/` does not exist and should stay that way.

| Intent                            | Task                                                  |
| :-------------------------------- | :---------------------------------------------------- |
| Full validation (the gate)        | `mise run check`                                      |
| Auto-fix formatting + lint        | `mise run fix`                                        |
| Regenerate every derived artefact | `mise run generate`                                   |
| Start Postgres                    | `mise run dev:db`                                     |
| Apply migrations + seed           | `mise run migrate`                                    |
| Run the API with reload           | `mise run dev`                                        |
| Query the database                | `echo 'select …;' \| mise run db:psql`                |
| Rebuild the DB from scratch       | `mise run dev:db:reset`                               |
| Generate + open the Xcode project | `mise run ios:gen` / `mise run ios:open`              |
| Build the apps headlessly         | `mise run ios:build` / `mise run ios:build:watch`     |
| Tests                             | `mise run test` (`test:rs`, `test:e2e`, `test:swift`) |

**Before committing** — three commands, in this order:

```bash
mise run generate   # 1. Protobuf, catalogue export, site figures, SQLx cache
mise run fmt        # 2. Format
mise run check      # 3. Full validation
```

`mise run check` does not include `check:swift` or `test:swift`, because both need a full Xcode toolchain that a headless environment may not have. Run them explicitly when touching `ios/`.

`check:diagrams` is out for the same reason — it builds `OndDiagrams` to redraw the marketing site's figures from the app's own geometry. Run it whenever you touch `ios/` or `web/`; without it the page keeps drawing a technique the app has since changed.

### Commit messages

`<prefix>: <description>`, where the prefix names the area, the feature, or the kind of change, and the description says what changed in the imperative.

The prefix is a hint for someone scanning `git log`, not a taxonomy. `technique:`, `ios:`, `proto:`, `migrate:`, `docs:`, `ci:`, `deps:` are all fine, and so is a conventional-commit type like `fix:` or `refactor:` when the _kind_ of change is more useful than the area. No `(scope)` brackets, no fixed vocabulary, nothing enforcing it — this is a convention because a log that reads consistently is faster to scan, not because a tool parses it.

Keep the subject under ~72 characters. The body is for _why_: the constraint that forced the approach, the alternative rejected, the regression it guards. Git already records what changed; it cannot reconstruct the reasoning.

### Testing

Philosophy and patterns in [docs/testing.md](docs/testing.md).

- **Rust unit** — inline `#[cfg(test)] mod tests` at the bottom of the file under test. Runner is cargo-nextest via `mise run test:rs`, which is scoped to lib and bin targets so it needs no database.
- **Rust integration** — `crates/api/tests/e2e/`, via `mise run test:e2e`. Drives the production router over a disposable `ond_test_<name>` database, one per test, using real gRPC-Web framing. Never point these at the dev database; the harness makes that structurally impossible and it should stay that way.
- **Swift** — Swift Testing, in `ios/Packages/OndCore/Tests/`. Runs on the host (the package declares a macOS platform for exactly this reason), so no simulator is needed.
