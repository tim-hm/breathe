# Architecture, Structure & Documentation — Review Reference

You are reviewing the codebase for architectural health: layering discipline, file/folder structure, god files, cohesion/coupling, and the accuracy of project documentation (including `CLAUDE.md`).

Use finding ID prefix: **ARCH**

---

## 1. Layering Discipline

### Rust — the three-layer contract

`docs/code-structure.md` fixes what each layer receives, owns, and never does:

| Layer           | Receives                                  | Owns                                        | Never does                      |
| :-------------- | :---------------------------------------- | :------------------------------------------ | :------------------------------ |
| `handlers/`     | `Arc<AppState>`                           | Transport concerns, request unwrapping      | Business rules                  |
| `service.rs`    | `&PgPool` and other explicit dependencies | Validation, orchestration, proto conversion | Raw SQL; taking `Arc<AppState>` |
| `repository.rs` | `&PgPool`                                 | All SQL                                     | Anything else                   |

**What to check:**

- **`Arc<AppState>` below the handler.** A service that takes `Arc<AppState>` can reach anything, which hides its real dependencies at the call site and makes it untestable in isolation. This is the single most load-bearing rule in the layering contract — grep `service.rs` files for `AppState`.
- **SQL outside `repository.rs`.** `sqlx::query`/`query_as!`/`query_scalar!` appearing in a service or handler.
- **Business rules in a repository.** Conditional logic that makes a domain decision (branching on status, computing an entitlement) rather than shaping a query.
- **Transport types below the handler.** `tonic::Request`/`Response`/`Status` or axum extractors imported into `service.rs` or `repository.rs`. Note the deliberate exception: `errors.rs` owns the `From<…> for tonic::Status` impl, and that is where transport mapping belongs.
- **Repositories as structs or traits.** They are free functions by design, with no trait abstraction — `sqlx::query_as!` checks every query against the real schema at compile time, and a mock would trade that guarantee away. Flag a newly introduced `Repository` struct or trait as a convention violation, not an improvement.
- **Handlers doing more than unwrap → call → map.**

### Swift — the target graph

`OndAPI` (not a product) ← `OndKit` (domain models, observable models, repositories) ← the app. `OndUI` has no dependencies at all.

**What to check:**

- **`import OndAPI` outside `OndKit`.** The target graph makes this unnameable from the app, so a working occurrence means the graph changed — check `Package.swift` and `ios/project.yml` for a dependency edge that shouldn't exist.
- **`OndUI` importing a domain type.** It exposes accents named for feeling (`settle`, `night`, `spark`, `restore`); the _feature_ maps `TechniqueGoal` onto them. A dependency here inverts the graph and makes the palette un-reusable.
- **Observable models in the app target.** Models belong in `OndKit`; the app target has no test bundle, so a model living there is structurally untestable. Views stay in `ios/Breathe/Features/<Name>/`.
- **Generated types above the repository boundary.** `docs/transport.md` states the rule for both languages: generated protobuf types stop at the repository. Above it, code works in domain types that have no unrepresentable state. A `Ond_V1_*` type in a view, a model, or anything the app can name is a finding.

**Severity guide:**

- Circular dependency between feature modules → Critical
- `service.rs` taking `Arc<AppState>` → Warning
- SQL outside `repository.rs` → Warning
- Generated protobuf type escaping the repository boundary → Warning
- `OndUI` depending on a domain type → Warning
- Handler with embedded business logic (>20 lines of non-mapping code) → Suggestion

---

## 2. File & Folder Structure

**Expected pattern:** Feature-first (vertical slice) organisation, not layer-first. Structure is chosen from a feature's actual complexity, not imposed preemptively.

**Module size tiers** (`docs/code-structure.md`):

- **Tier 1** (< ~150 LOC, single concern) — one file, no subdirectories
- **Tier 2** (150–500 LOC, or 3+ concerns) — `mod.rs` becomes pure declaration + re-export; logic moves to named siblings
- **Tier 3** (500+ LOC, multiple surfaces) — nested subdirectories per concern

**What to check:**

- **`mod.rs` over ~50 lines.** It holds `mod` declarations and `pub use` re-exports only. Past 50 lines, logic has leaked in.
- **Tier mismatch.** A feature at 600 LOC still flat in one file, or a 90-LOC feature split across six files with a module file. Both are findings; the second is the more common mistake.
- **Missing feature files where the logic exists.** A feature with real SQL and no `repository.rs`, or real error mapping and no `errors.rs`.
- **Filename prefixed with the feature name.** `technique/handlers/technique_grpc.rs` is noise — the module path already says it.
- **Swift naming.** PascalCase, named for the principal type, with `-View` / `-Model` / `-Tests` suffixes. A Swift file holding several unrelated principal types is a finding.
- **`utils/` or `helpers/` directories.** Explicitly banned as junk drawers. Also flag `utils.rs`, `helpers.rs`, `common.rs`, `misc.swift` — the same anti-pattern at file scale.
- **Escalation without a second consumer.** The three-tier rule says code starts feature-local and moves up only when a _concrete_ second consumer exists. Flag things promoted to `src/http/`, `src/state.rs`, or `OndKit` speculatively. Flag the creation of a `shared` crate outright — `docs/architecture.md` says it should not exist until a second crate genuinely needs a type.
- **Orphaned files:** files in `crates/api/src/` root that belong inside a feature.

**Severity guide:**

- `utils/` or `helpers/` directory → Warning (explicit convention violation)
- New `shared` crate with a single consumer → Warning
- `mod.rs` containing logic → Suggestion
- Tier mismatch (structure imposed or overdue) → Suggestion
- Feature-name-prefixed filename, or a mis-suffixed Swift file → Suggestion
- Orphaned files with no clear owner → Suggestion

---

## 3. God Files

A "god file" does too much. It has more than one clear responsibility, or it exceeds a reasonable size threshold.

**What to check:**

- Files exceeding the configured god file line threshold (Rust and Swift have separate thresholds). Use the heat map to prioritise — god files that are also hot are the highest priority.
- Files with multiple unrelated public exports (heuristic: exports that serve different features or domains)
- Files that multiple unrelated modules depend on (high fan-in from diverse sources)
- Single files that contain both type definitions AND business logic AND SQL

**How to make findings actionable:** Don't just say "this file is too long." Propose a specific split:

- Which responsibilities to extract
- What the new files/modules should be named — follow the repo's naming conventions, not generic ones
- Which functions/types move where
- How the remaining file's API changes

**Excluded from this check:** `crates/migrate/src/seed.rs` is long by design — it is the curated catalogue, data rather than logic, and `docs/architecture.md` says so. Flag it only if executable logic has accumulated alongside the data.

**Severity guide:**

- God file >2x threshold AND hot → Warning
- God file >threshold but stable (not hot) → Suggestion
- God file with mixed responsibilities (types + logic + SQL) → Warning

---

## 4. Documentation Accuracy & Drift

Treat documentation as a first-class part of the codebase. Review whether the project's docs and `CLAUDE.md` still describe reality — misleading documentation is worse than none, because it actively sends readers (and agents) the wrong way.

**What to check:**

### CLAUDE.md correctness

`AGENTS.md` is a symlink to `CLAUDE.md`, so there is one file to check, not two. If it has become a real file with diverging content, that itself is a finding.

- File/module/path references it cites still exist (`crates/api/src/state.rs`, `crates/api/src/grpc.rs`, the `docs/*.md` links, the directory layouts in "Where code lives").
- Commands it prescribes still work — every `mise run <task>` named in the doc must exist in `.mise.toml`. Cross-check the task table in §3 against `mise tasks`.
- The port block (18100–18199, API 18100, Postgres 18101) matches `.mise.toml` and `compose.yaml`.
- The environment-variable claim in §1.4 — "the backend reads exactly three" — still holds. Grep for `env::var` / `std::env` across `crates/` and flag any fourth.
- Patterns it describes are still the ones the code follows.

### docs/ freshness vs. code

- Read `docs/architecture.md`, `code-structure.md`, `transport.md`, `observability.md`, `testing.md`, `contributing.md`, `deployment.md`.
- Statements of the form "no X yet" are the ones most likely to have expired: "No auth", "no `shared` crate", "no metrics, no tracing export", "no hand-written retry loop exists yet", "No handler needs this yet". Each names a condition that a new feature can silently invalidate. Check every one against the current tree and flag the ones that have.
- `docs/architecture.md` and `docs/testing.md` carry tables enumerating components and tests. A feature or e2e test added without its row is drift.
- Identify modules/features that exist in code but are undocumented — the feature list in `docs/architecture.md` is the reference.
- Check that documented module boundaries match the actual import graph.

### Stale references & broken links

- Docs mentioning files, modules, or mise tasks that no longer exist.
- Broken intra-repo doc links. `mise run check:doc-links` covers these mechanically — if a link is broken, the gate is either failing or not covering that file, and which one it is matters.

**Severity guide:**

- `CLAUDE.md` or a doc actively misleading on a hot path (wrong command, wrong layout, contradicts current code) → Warning
- An expired "not yet present" claim in `docs/` → Warning
- Documented pattern actively violated in new code (hot files) → Warning
- Module/feature exists in code but not in the `docs/architecture.md` component table → Suggestion
- Stale references / broken doc links to deleted code → Suggestion

---

## 5. Cohesion & Coupling

**Cohesion:** A module should be internally cohesive — most of its dependencies are within the module itself.

**Coupling:** Cross-feature dependencies should be rare and one-directional.

The invariants from `docs/code-structure.md`, each of which is directly checkable:

- **Axis of change** — a feature change touches at most two top-level directories.
- **Deletability** — removing a feature directory removes >80% of that feature's code.
- **No backdoor imports** — nothing bypasses a feature's public surface. In Rust, look for `pub(crate)` items reached from another feature, or `use crate::features::other::repository::…` skipping past `service`.
- **No circular feature dependencies** — if A imports from B, B must not import from A.
- **Dependencies flow inward** — features depend on shared infrastructure, never the reverse. `state.rs`, `grpc.rs`, and `http/` importing feature types is expected (they are the composition points); a feature importing from another feature to reach infrastructure is not.

**What to check:**

- **Circular dependencies** at the feature level, in both languages.
- **Leaky abstractions:** internal types imported across a feature boundary.
- **Shotgun surgery indicators:** use the heat map — a single conceptual change touching 5+ unrelated modules means the seam is in the wrong place.
- **Composition-point bloat:** `grpc.rs` and `http/mod.rs` are single aggregation points by design. Check they still only aggregate — a `match` on feature state there is logic that belongs in a feature.

**Severity guide:**

- Circular dependency between feature modules → Critical
- Backdoor import bypassing a feature's public surface → Warning
- Internal type leaking across a module boundary → Warning
- Logic accumulating in `grpc.rs` / `http/mod.rs` → Warning
- Shotgun surgery pattern (commit touching 5+ unrelated modules) → Suggestion
