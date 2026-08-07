# Type Safety & Robustness — Review Reference

You are reviewing the codebase for type safety: newtype discipline, type system hygiene, making illegal states unrepresentable, and null/error safety across Rust and Swift.

Use finding ID prefix: **TYPE**

`CLAUDE.md` §1.1 is the baseline: code must be strongly typed, avoiding `any`, `as`, force-unwraps, and other escape hatches. Inferred types are fine inside function bodies; signatures and complex types are explicit.

---

## 1. Newtype Discipline

IDs, keys, and domain-specific values should carry their meaning in the type, not in a comment or a parameter name.

### Rust

- Functions accepting a bare `Uuid`, `String`, or `i64` where a newtype exists. `crates/api/src/identity.rs` defines `UserId(Uuid)` and explains why: an extension lookup on a bare `Uuid` could silently match some other id the request happens to be carrying. Any function that takes a user identifier and does not take `UserId` is spending that guarantee.
- Two or more parameters of the same primitive type representing different domain concepts — the classic silent-swap bug. `fn record(user: Uuid, technique: Uuid)` can be called with the arguments reversed and will compile.
- Domain values with a validity rule enforced only at the call site: a slug that must be non-empty, a duration that must be positive, an ordinal that must be non-negative.
- Ordinals and slugs are load-bearing in this schema (`(…, ordinal)` keys, seed upserts keyed on `slug`). Values whose ordering or uniqueness the database depends on are the strongest candidates for a newtype.

### Swift

- Model properties and initialiser parameters typed `String` or `UUID` where the domain has a specific concept. Check `OndKit`'s domain models — a `TechniqueId` type used in some places and a raw `String` in others is worse than either alone.
- Where a Rust newtype exists and the Swift side uses a primitive for the same concept, say so: the contract is one thing described twice, and the weaker description is where the bug lands.

**Severity guide:**

- Two+ parameters of the same primitive type representing different domain concepts → Warning
- Function accepting a raw primitive where a newtype exists in the same module → Warning
- A concept modelled as a newtype in Rust but a primitive in Swift (or vice versa) → Warning
- Isolated raw primitive in internal code where confusion is unlikely → Suggestion

---

## 2. Type System Hygiene

### Rust hygiene

The workspace lints in `Cargo.toml` already deny or warn on much of this — `unwrap_used`, `expect_used`, `panic`, `dbg_macro`, `print_stdout`, `todo`, `unimplemented`, `unsafe_code`, `await_holding_lock`, `redundant_clone`. Your job is not to re-report what clippy would catch on the next `mise run check`. Focus on:

- **`#[allow(…)]` escapes.** Every `#[allow(clippy::unwrap_used)]`, `#[allow(clippy::panic)]`, or similar in non-test code is a deliberate hole. `CLAUDE.md` §1.2 requires the justification to be kept verbatim — an `allow` with no reason attached is a finding regardless of whether the escape is defensible.
- **Catch-all match arms on contract enums.** `docs/transport.md` states the rule: the database-enum-to-proto-enum conversion uses a `match` with no catch-all, so adding a database variant without a proto variant fails to compile. A `_ =>` arm on a proto or database enum silently converts that compile error into a runtime default. This is the single highest-value check in this section.
- **`as` casts.** Numeric `as` truncates silently (`i64 as i32`, `usize as u32`). Prefer `try_into()` with a handled error. Flag every `as` on a value that could exceed the target range.
- **`let _ = <Result>`.** `let_underscore_drop` is warned at the workspace level, but the pattern also appears as `if let Ok(x) = …` with no `else`, which clippy does not see. Both discard an error with no record.
- **Stringly-typed state.** `match` or `if` on a string where an enum would be exhaustive. The schema uses native Postgres enums (`technique_goal`, `phase_kind`) precisely so this stays impossible — flag anywhere a value crosses back into a `String`.
- **`chrono::Local`.** `clippy.toml` disallows it and says why (all times are UTC). If one has appeared behind an `allow`, that is a Critical-adjacent finding — it produces values that compare as if they were the same instant when they are not.
- **Over-broad trait bounds** and unnecessary `Clone` on large types in hot paths.

### Swift hygiene

Swift has no equivalent workspace lint file, so these checks carry the weight:

- **Force unwraps.** `!` on an optional, `try!`, `as!`, and implicitly-unwrapped-optional declarations (`var x: Foo!`). Each is a crash the type system offered to prevent. Acceptable only where the safety is provable _and_ commented; flag the ones that aren't.
- **`fatalError` / `preconditionFailure` in non-test code.** A crash is not error handling. The exception is a genuinely unreachable branch, which should say so.
- **`Any` / `AnyObject` / `[String: Any]`.** Each is a missing concrete type. Flag unless at a serialisation boundary with a comment explaining why.
- **`@unchecked Sendable`.** An assertion the compiler cannot verify. It needs a comment proving the invariant, or it is a data race waiting for a scheduler change.
- **Missing explicit signatures on public API.** `CLAUDE.md` §1.1 requires explicit types on function signatures. Public functions and initialisers in `OndKit` / `OndUI` relying on inference are findings; locals inside a body are not.
- **`?? default` swallowing a domain failure.** A nil-coalescing operator that turns a missing required value into a plausible-looking one is the Swift form of silent error swallowing. Distinguish it from a genuine default (an optional preference with a sensible fallback), which is fine.

**Severity guide:**

- Catch-all `_ =>` arm on a proto or database enum → Warning
- Force unwrap / `try!` / `as!` in non-test Swift → Warning
- `#[allow(…)]` on a panicking-path lint with no justification → Warning
- `as` cast that can truncate a value in range of the source type → Warning
- `@unchecked Sendable` with no invariant comment → Warning
- Error discarded via `let _ =` or a bare `if let Ok` → Warning
- `Any` / `[String: Any]` outside a serialisation boundary → Warning
- Missing explicit return type on a public Swift function → Suggestion
- Unnecessary `.clone()` in a hot path → Suggestion

---

## 3. Making Illegal States Unrepresentable

The type system should prevent invalid states from being expressible.

**What to check:**

- **Optional fields that are conditionally required.** A struct where `status` being one variant makes another field mandatory. This should be an enum with associated values (Swift) or a data-carrying enum (Rust), not a struct of optionals. The stage/phase model is the pattern to compare against: an open-ended retention and a fixed cycle are different shapes, and the types should say so.
- **Boolean flags forming an implicit state machine.** `isLoading` / `isError` / `hasData` on an observable model can express combinations that mean nothing. A single `enum LoadState { idle, loading, loaded(T), failed(Error) }` cannot. Check every `-Model` in `OndKit` for this.
- **Parallel collections that must stay index-aligned.** Two arrays where element _i_ of one describes element _i_ of the other.
- **Proto zero values escaping as domain values.** Every proto3 enum has an `_UNSPECIFIED = 0` the wire can always produce. `docs/transport.md` fixes the handling: Rust maps explicitly, and Swift's `init?(proto:)` returns `nil` for `.unspecified` and `.UNRECOGNIZED`, which the repository turns into `malformedResponse`. A conversion that maps `.unspecified` onto a real domain case — or defaults it — puts a value in front of a user that the server never sent. Check every generated-enum conversion in `OndKit`.
- **Loosely typed configuration.** `HashMap<String, String>` or `[String: Any]` where a struct with named fields would be checked. `crates/api/src/config.rs` derives configuration by convention specifically so this doesn't accumulate.

**Severity guide:**

- Proto `_UNSPECIFIED` / `UNRECOGNIZED` mapping to a real domain case or a default → Critical
- Boolean flags creating impossible states in a core domain type or observable model → Warning
- Conditionally-required optional field with no enum modelling it → Warning
- Stringly-typed state where an enum exists or should exist → Warning
- Parallel index-aligned collections → Suggestion

---

## 4. Null/Error Safety

### Rust error safety

- **Fallible functions return `Result`.** Not a sentinel, not an `Option` that loses the reason, not a panic.
- **Typed error enums.** Each feature owns an `errors.rs` with a `thiserror` enum and a `From<…> for tonic::Status` impl. A feature that returns `anyhow::Error` or a `String` from its service layer has no way to distinguish a client mistake from a server fault, and the transport layer then has to guess.
- **Error context on propagation.** A bare `?` at a boundary where the caller has context worth attaching.
- **Silent swallowing.** Covered above under hygiene, but worth restating as an error-safety concern: an error that is neither logged nor propagated did not happen, as far as anyone debugging is concerned.
- **`unwrap_or_default()` on a domain value.** An empty `Vec` where a query failed is indistinguishable from an empty result set. `docs/testing.md` names exactly this shape as worth guarding — a corrupt row must fail the call rather than quietly shorten a list.

### Swift error safety

- **`throws` over optional returns** where the caller needs to know _why_. `TechniqueRepositoryError.malformedResponse` is the pattern: a decode that could not represent the value throws, so the failure has a name.
- **Typed errors over `NSError` / generic `Error`.** A `catch` that only reads `error.localizedDescription` cannot branch on what went wrong.
- **`catch` blocks that swallow.** An empty catch, or one that only sets a UI flag without recording the cause.
- **Streaming termination.** `docs/transport.md` notes the hazard: over gRPC-Web a terminal `.complete` carrying a non-OK code must become a thrown error, because a stream that simply stops is indistinguishable from a short answer. Check every `AsyncThrowingStream` wrapper for this.
- **Task cancellation.** A `Task` whose failure path neither surfaces nor logs — the async equivalent of an ignored `Result`.

**Severity guide:**

- Stream terminating on a non-OK status without throwing → Critical
- `unwrap_or_default()` masking a query failure as an empty result → Warning
- Service layer returning an untyped error instead of its feature's error enum → Warning
- Empty or cause-discarding `catch` block → Warning
- Missing error context on propagation in a critical path → Suggestion
