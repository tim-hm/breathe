# Code Structural Strategy

How code is organised across the repo. The same philosophy governs Rust crates and Swift packages; only the idioms differ.

## Guiding Principle

**Couple along the axis of change.** When a feature changes, the blast radius should be one directory. Code is organised feature-first, layer-second: the primary unit is a domain feature (`technique`, later `session`, `streak`); within a feature, code is subdivided by concern. Transport protocols (gRPC, HTTP) and UI layers (views, models) are dimensions _within_ a feature, not containers for features.

### Why not layer-first?

Layer-first groups code by technical role, and fragments features as the codebase grows — one change touches `handlers/`, `services/`, `repositories/`, `types/`. Feature-first inverts this:

```text
# Rust
crates/api/src/features/technique/
  mod.rs
  handlers/grpc.rs
  service.rs   repository.rs   types.rs   errors.rs

# Swift
ios/Breathe/Features/Techniques/
  TechniqueListView.swift
ios/Packages/OndCore/Sources/OndKit/
  TechniqueListModel.swift
```

A developer can understand — or delete — a feature by looking in one place.

Swift splits one layer further than Rust: the view stays in the app feature directory, but its observable model lives in `OndKit`. The app target has no test bundle — package tests are the only tests that run on the host — so a model in the app target would be structurally untestable.

## The layering contract

Inside a Rust feature, three layers with fixed responsibilities:

| Layer           | Receives                                  | Owns                                         | Never does                      |
| :-------------- | :---------------------------------------- | :------------------------------------------- | :------------------------------ |
| `handlers/`     | `Arc<AppState>`                           | Transport concerns, auth, request unwrapping | Business rules                  |
| `service.rs`    | `&PgPool` and other explicit dependencies | Validation, orchestration, proto conversion  | Raw SQL; taking `Arc<AppState>` |
| `repository.rs` | `&PgPool`                                 | All SQL                                      | Anything else                   |

A service that takes `Arc<AppState>` can reach anything, which makes its real dependencies invisible at the call site and untestable in isolation. Explicit parameters are the point.

Repositories are **free functions**, not a `Repository` struct, and there is no trait abstraction over them. A mocking seam would let a test pass against a query the database would reject — and `sqlx::query_as!` already checks every query against the real schema at compile time, which is the guarantee a mock would be trading away.

## Naming Conventions

The module path provides context — **don't prefix filenames with the feature name.** `technique/handlers/grpc.rs` is unambiguous; `technique/handlers/technique_grpc.rs` is noise.

### Rust

| Element       | Convention                     | Example              |
| :------------ | :----------------------------- | :------------------- |
| Files/modules | snake_case                     | `repository.rs`      |
| Module entry  | `mod.rs`                       |                      |
| Doc comments  | `//!` at the top of every file | `//! Technique SQL.` |

### Swift

Swift diverges from Rust here, and deliberately: the language convention is one principal type per file, named after it. Following the Rust convention instead would fight every tool in the ecosystem.

| Element           | Convention                               | Example                        |
| :---------------- | :--------------------------------------- | :----------------------------- |
| All files         | PascalCase, named for the principal type | `TechniqueListView.swift`      |
| Views             | `-View` suffix                           | `TechniqueListView.swift`      |
| Observable models | `-Model` suffix                          | `TechniqueListModel.swift`     |
| Tests             | `-Tests` suffix                          | `TechniqueDecodingTests.swift` |

## Three-Tier Escalation

Every piece of code has a default home. Start at the lowest tier and escalate only when a **concrete** second consumer exists — never speculatively.

1. **Feature-local** (the default home for all new code) — Rust: `crates/api/src/features/<name>/`. Swift: `ios/Breathe/Features/<Name>/`.
2. **App-local** (a second feature in the same target needs it) — Rust: top-level modules like `src/http/`, `src/state.rs`. Swift: `ios/Breathe/` root.
3. **Shared crate/module** (a second target needs it) — Rust: a `shared` crate, which **does not exist yet and should not be created until it does**. Swift: a target in `ios/Packages/OndCore` — `OndKit` for domain, `OndUI` for design.

**Rule for tier 2:** if at least two features call into it _and_ its job is to wrap or mediate against an external system (the database, the network), it belongs at the top level. If it owns user-visible domain behaviour, it belongs inside a feature.

## Swift module boundaries

All Swift library code lives in **one** SwiftPM package, `ios/Packages/OndCore`, split into targets. One package rather than three because SwiftPM cannot share a tools-version or platform list across packages — and, more importantly, because each package carries its own `Package.resolved`, so a split means several lockfiles free to pin different versions of the same dependency.

| Target               | Product? | Role                                                       | May depend on            |
| :------------------- | :------- | :--------------------------------------------------------- | :----------------------- |
| `OndAPI`             | **no**   | Generated protobuf + the Connect client factory            | Connect, SwiftProtobuf   |
| `OndKit`             | yes      | Domain models, observable feature models, and repositories | `OndAPI`                 |
| `OndUI`              | yes      | Design tokens and shared components                        | nothing                  |
| `OndStyle`           | yes      | Mappings from a domain type onto a design token            | `OndKit`, `OndUI`        |
| `Breathe` (iOS)      | —        | Features, composition root                                 | the three products above |
| `OndWatch` (watchOS) | —        | Features, composition root, the phone link                 | the three products above |

Two invariants hold here, and the target graph enforces both:

- **Neither app can import `OndAPI`.** It is a target, not a product, so the module is not merely undeclared in `project.yml` — it is unnameable from an app. "App code never imports a generated protobuf type" is checked by the compiler rather than remembered.
- **`OndUI` knows nothing about the domain.** It has no dependencies at all. It exposes accents named for feeling (`settle`, `night`, `spark`, `restore`), and something above it maps `TechniqueGoal` onto them — a design module that imported domain types would invert the dependency and make the palette un-reusable. `OndStyle` is where that mapping lives, which is the point of it existing: it can name both sides precisely because nothing depends on _it_.

### What the two apps share

`OndWatch` is a second app over the same package. Everything platform-neutral is already in `OndKit` and the watch composes the same instances — the session timeline, the catalogue cache, the local session store, the sync queue. Views are never shared: a wrist is not a small phone, and `BreathRing` exists precisely because there is only room for one shape where the phone has two.

What falls between the two is a mapping from a domain type onto a design token. `OndUI` cannot hold one by the invariant above, so `OndStyle` does: it depends on both products, which is exactly what lets it name a `TechniqueGoal` and an accent in the same function. `GoalAccent` lives there and both apps read it, so the wrist and the hand cannot drift to different colours for the same technique.

The line is between a **mapping** and a **view**. A mapping goes in `OndStyle`; a view stays duplicated per target, because a wrist is not a small phone and the two really do want different layouts. `SafetyNote` and `TechniqueGlyph` are the two that duplicate today — both views, and both should stay that way until their bodies stop diverging rather than because they are small. `TechniqueGlyph` is the weaker of the two: its copies differ only in a default line width, so if it diverges no further it is the next thing that belongs in `OndStyle`.

The same rule catches one pair the compiler cannot see at all. `OndKit/TechniqueDrawing.swift` is a coordinate-for-coordinate port of the hand-authored SVGs in `web/index.html`, and the site is the reference — so a glyph changed there is a glyph the apps keep drawing the old way, with nothing to catch it.

The link between the two apps runs one way: the phone sends the anonymous identity and the best controlled pause through `WatchConnectivity`'s `applicationContext` (`ios/Breathe/WatchLink.swift`), and the watch only listens (`ios/OndWatch/PhoneLink.swift`). The watch must never mint an identity of its own, so `ProvisionedUserIdentityStore` starts empty and everything above it is written to work without one — the reasoning is on that type.

## Module Size Tiers

Choose structure from a feature's actual complexity. Don't impose it preemptively.

- **Tier 1** (< ~150 LOC, single concern) — everything in one file. No subdirectories, no module file.
- **Tier 2** (150–500 LOC, or 3+ concerns) — the module file becomes pure declaration + re-export; logic moves to named siblings. `features/technique/` is here.
- **Tier 3** (500+ LOC, multiple surfaces) — nested subdirectories per concern.

`mod.rs` contains `mod` declarations and `pub use` re-exports only. If it grows past ~50 lines, logic has leaked in.

## Test Placement

Unit tests are colocated with their source in both languages.

- **Rust** — inline `#[cfg(test)] mod tests` at the bottom of the file under test.
- **Swift** — `ios/Packages/OndCore/Tests/<Target>Tests/`, which is where SwiftPM requires them.

Integration tests are the exception, because they belong to no single file: `crates/api/tests/e2e/` mirrors the feature layout one level up — `technique.rs` for the feature, `health.rs` for the JSON surface, `harness.rs` for the shared machinery. Cargo treats `tests/e2e/main.rs` as one target, so all of them compile into a single binary rather than one per file.

This is why `crates/api` has a `lib.rs` at all. An integration test cannot reach into a binary crate, so `main.rs` holds process startup and nothing else, and the router it serves is assembled in `lib.rs` where the harness can build the same one.

## Invariants

These hold at every tier, in both languages:

- **Axis of change**: a feature change touches at most two top-level directories — the feature's, and possibly one shared location.
- **Deletability**: removing a feature directory removes > 80% of that feature's code.
- **No backdoor imports**: nothing bypasses a feature's public surface.
- **No circular feature dependencies**: if A imports from B, B must not import from A.
- **Dependencies flow inward**: features depend on shared infrastructure, never the reverse.
- **Generated types stop at the repository boundary** (see [transport.md](transport.md)).
- **No junk drawers**: `utils/` and `helpers/` directories must not exist. If shared logic has no obvious home, that's a signal to think harder — most premature abstractions dissolve once features own their own code.

## References

- [Vertical Slice Architecture](https://www.jimmybogard.com/vertical-slice-architecture/) — Jimmy Bogard. "Couple along the axis of change" comes from here.
- [Move files around until it feels right](https://react-file-structure.surge.sh/) — Dan Abramov. The pragmatic counterweight: no file structure is correct on day one.
