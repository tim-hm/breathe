# Code Quality & Hygiene — Review Reference

You are reviewing the codebase for code quality and repo hygiene: single responsibility, dependency discipline, DRY, dead code & artefacts, and test coverage gaps.

Use finding ID prefix: **QUAL**

---

## 1. Single Responsibility

Functions and modules should have one clear responsibility.

**What to check:**

### Functions

- Functions longer than ~50 lines containing multiple distinct logical steps. `CLAUDE.md` §1.2 gives the tell: "a body needing a signpost every few lines wants a named function instead." A run of step-marker comments is the symptom; the extraction is the fix.
- Functions with multiple side effects — one that validates, queries, records a journey entry, and logs should be orchestrated from above, not fused.
- Functions whose name doesn't describe everything they do.
- Swift observable models (`-Model` types in `BreatheKit`) that both fetch and transform and format for display. The model owns state and the transitions between states; formatting belongs to the view.

### Modules/Files

- Grab-bag files: `utils.rs`, `helpers.rs`, `common.rs`, or their Swift equivalents. `docs/code-structure.md` bans the directory form outright and the file form is the same anti-pattern one tier down.
- A single type handling transport parsing, business logic, and SQL — the layering contract exists to prevent exactly this.
- Modules whose public API serves unrelated consumers. Heuristic: if describing it needs an "and", it probably has two responsibilities.

**How to make findings actionable:** Propose specific extractions — which functions move, what the new file is called (following the naming conventions), and how the remaining API changes.

**Severity guide:**

- Module mixing 3+ unrelated concerns → Warning
- Function >100 lines with multiple responsibilities → Warning
- Grab-bag `utils`/`helpers` module or file → Warning (explicit convention violation)
- Function >50 lines with a clear extraction opportunity → Suggestion

---

## 2. Dependency Discipline

This project inverts dependencies through **explicit parameters**, not through traits. Read `docs/code-structure.md` before flagging anything here — the absence of a `Repository` trait is a decision with a stated reason, not an oversight:

> A mocking seam would let a test pass against a query the database would reject — and `sqlx::query_as!` already checks every query against the real schema at compile time, which is the guarantee a mock would be trading away.

So the checks are not "is there an interface at this boundary" but:

**What to check:**

- **`Arc<AppState>` below the handler layer.** This is the real dependency-inversion violation in this codebase. A service taking `AppState` can reach anything, which hides its dependencies at the call site and makes it untestable in isolation. Services take `&PgPool` and other explicit dependencies.
- **Handlers reaching past the service into a repository.** The handler's job is transport; skipping the service layer moves validation and orchestration into the transport layer where the e2e tests are the only thing that can see it.
- **Newly introduced repository traits or `Repository` structs.** Flag as a convention violation and cite the reason above.
- **Swift models constructing their own transport.** A `-Model` in `BreatheKit` that builds a Connect client rather than receiving a repository has hard-wired itself to the network and cannot be tested on the host — which is the whole reason models live in the package.
- **Global mutable state** in either language standing in for a passed dependency.

**Severity guide:**

- `service.rs` taking `Arc<AppState>` → Warning
- Handler bypassing the service to call a repository directly → Warning
- Swift model constructing its own client instead of receiving a repository → Warning
- New repository trait or struct introduced → Warning (convention violation — say why)

---

## 3. DRY — Duplicated Logic

**What to check:**

- **Near-duplicate code blocks:** functions or sections 80%+ similar, differing only in a parameter. Check within a feature and across features.
- **Divergent implementations:** two implementations of the same concept that have drifted — two error-mapping shapes, two ways of ordering stages, two ways of deciding an entitlement.
- **Copy-paste patterns:** verbatim sequences in several places. Common targets here: `From<…> for tonic::Status` bodies, proto-to-domain conversions, e2e test setup.
- **Cross-language duplication of a _rule_.** A validation enforced in `service.rs` and re-implemented in a Swift model is not a DRY violation — the two ends are separate programs and `proto/` is the shared artefact. But the _rule_ drifting between them is a correctness finding, and belongs in the report as one.

**How to make findings actionable:**

- Identify every instance
- Propose the shared abstraction and where it lives, following three-tier escalation: feature-local first, app-local (`src/http/`, `BreatheKit`) only when a second feature genuinely needs it, a shared crate only when a second _target_ does — and `docs/architecture.md` says that crate should not exist yet

**Important caveat:** `CLAUDE.md` says one duplication is acceptable, two is worth noting, three warrants a refactor. Don't flag the first.

**Severity guide:**

- 3+ instances of duplicated business logic → Warning
- 2 divergent implementations of the same concept → Warning
- The same rule implemented differently in Rust and Swift → Warning
- Copy-paste in test setup → Suggestion
- Minor structural similarity → Do not flag

---

## 4. Dead Code & Artefacts

Code, files, and debt markers that are no longer pulling their weight should be removed. Version control preserves history — the working tree should reflect what the project needs _now_.

**What to check:**

### Dead code

- **Public items with no callers.** Grep the name across the repo. Note that `pub` in these crates means "reachable from the binary and from `tests/`" (see the `must_use_candidate` justification in `Cargo.toml`), so a `pub` item used only by an e2e test is alive.
- **Unused feature flags or config values:** a field in `config.rs` nothing reads, a derived value nothing consumes.
- **Commented-out code blocks.** `CLAUDE.md` bans committing these outright.
- **Unreachable code:** after early returns, match arms that cannot be reached, branches behind a constant condition.
- **Unused dependencies.** `mise run check:deps` covers this mechanically — if it passes and you believe a dependency is unused, check whether the task's scope has a hole before filing.
- **Orphaned migrations or seed entries:** a seeded technique nothing references, a column no query selects.

### Repo artefacts

- **Committed build output:** stray files under `target/`, `.build/`, `DerivedData/`, or generated files checked in alongside source. The one legitimately committed generated tree is `BreatheAPI/Generated/`, and `mise run check:generated` owns its freshness.
- **Leftover temp/backup files:** `*.bak`, `*.orig`, `*.rej`, `*~`, `.DS_Store`, `*.swp`, stray `tmp/` scratch.
- **Loose scripts.** `CLAUDE.md` §3 states `scripts/` does not exist and should stay that way — helper tooling is a mise task. A committed shell or Python script anywhere in the tree is a finding, not a convenience.

### Noise comments (CLAUDE.md §1.2)

- **Restatements:** comments the adjacent code says as well or better — `// Sort by ordinal` above an `ORDER BY ordinal`, `// the goal` labelling a `goal` field.
- **Comments about distant code:** section banners (`// ── Types ──`, `// ==== Helpers ====`, `// MARK: - Helpers` used as a banner over unrelated code) and group labels over runs of fields. They assert a file layout nothing enforces and rot invisibly.
- **Edit narration:** "Added in…", "Changed from…" — git holds that.
- **Not findings:** step markers segmenting a genuinely long body, anchored non-deducible facts, deliberate-weirdness warnings, `SAFETY:` / `TODO` / pragmas (`#[allow(...)]` justifications, `swiftlint:disable`), and doc comments. These are the sanctioned forms and `CLAUDE.md` says to keep them verbatim.

### Missing doc comments

The inverse also fails the convention: `docs/code-structure.md` requires `//!` at the top of every Rust file, and `CLAUDE.md` §1.2 requires a `///` block on every public function, every enum, and every non-obvious exported type — carrying the _why_, not a restatement of the signature. A new public API with no doc comment is a finding.

### Debt markers

- **`TODO` / `FIXME` / `HACK` / `XXX` clusters** in changed modules, especially ones referencing work that has since shipped or a known bug left unfixed.
- **Abandoned skipped tests:** `#[ignore]` in Rust, `.disabled` / commented-out `@Test` in Swift, left with no tracked removal condition.

**Severity guide:**

- Unreachable code in a critical path → Warning
- Dead feature flag still affecting code paths → Warning
- Loose script under `scripts/` or elsewhere instead of a mise task → Warning (explicit convention violation)
- Large block of commented-out code (>10 lines) → Suggestion
- Restatement comment, section banner, or edit-narration comment → Suggestion
- Missing `//!` module doc or `///` on a new public item → Suggestion
- Public item with zero callers → Suggestion
- Unused dependency → Suggestion
- Committed build artefact, backup/temp file, or orphaned script → Suggestion
- Abandoned skipped test with no tracked removal condition → Suggestion
- Cluster of stale `TODO`/`FIXME` referencing shipped or buggy work → Suggestion

---

## 5. Test Coverage Gaps

Read `docs/testing.md` before filing anything in this section. The project's position is "Write tests. Not too many. Mostly integration," and it names four things it deliberately does not test:

- **Trivial CRUD** — a repository function that is one `SELECT` with no logic is verified by `sqlx::query_as!` at compile time, more thoroughly than a test could
- **Type conversions with no rules** — a field-by-field copy
- **Thin wrappers** — where the body is one call to something else
- **Framework behaviour** — axum routing, SwiftUI layout, sqlx pooling

A finding against any of those is not a finding. The question the doc poses is the one to ask: _if this broke, would anything else notice?_ If a compile error, a failing query, or a visibly broken screen catches it first, the test is redundant.

**What to check:**

### Untested decisions

The tests worth having pin a decision that is invisible in the code and expensive to rediscover — an enum that must not decode to a default, a seed keyed on `slug` where a duplicate would let array order decide, a query string that must survive onto a maintenance URL. Cross-reference the heat map for changed logic of that shape with no matching test change.

### Boundary coverage

- **New RPCs with no e2e test.** `crates/api/tests/e2e/` drives the real gRPC-Web framing, and `docs/transport.md` explains why that matters: a failed call still returns HTTP 200 with the status in trailers, so a test that called the service function directly could never catch an error that fails to reach the client. A new RPC without one is untested at the only layer that counts.
- **Error paths.** A test suite where every assertion is a success. `a_stageless_technique_fails_the_call_rather_than_vanishing` is the shape to look for — a corrupt input failing loudly rather than quietly shortening a list.
- **Both sides of a contract change.** A proto change with a Rust test and no Swift decoding test (or the reverse) leaves half the boundary unpinned.

### Test quality

- Tests asserting implementation details — internal call order, private state — that break on refactors which change no behaviour.
- Tests with no meaningful assertion, or only a non-nil check.
- Rust test names should be declarative sentences (`doubles_embedded_quotes`); Swift `@Suite`/`@Test` should carry prose descriptions, because those strings are what a failure prints. A test named `test_1` costs a reader the same as a missing one.

### Test placement

- **Rust unit** — inline `#[cfg(test)] mod tests` at the bottom of the file under test.
- **Rust integration** — `crates/api/tests/e2e/`, mirroring the feature layout.
- **Swift** — `ios/Packages/BreatheCore/Tests/<Target>Tests/`.
- Duplicated fixtures across test files that belong in `harness.rs`.

**Severity guide:**

- New RPC with no e2e test → Warning
- Changed logic guarding a non-obvious decision, with no test change → Warning
- Contract change tested on one side of the boundary only → Warning
- Only happy-path tests for logic with error branches → Suggestion
- Tests asserting implementation details → Suggestion
- Duplicated fixture that belongs in `harness.rs` → Suggestion
