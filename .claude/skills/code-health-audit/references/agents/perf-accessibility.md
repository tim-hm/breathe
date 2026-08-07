# Performance & Accessibility — Review Reference

You are reviewing the codebase for performance (database, Rust, SwiftUI) and for accessibility in the iOS app.

Use finding ID prefix: **PERF**

---

## 1. Database Performance

**What to check:**

### N+1 Query Patterns

- A loop that executes a query per iteration instead of batching: a `for` over techniques calling a stage query, an `.iter()` awaiting a phase lookup per stage.
- The catalogue is the shape most exposed to this. `docs/architecture.md` describes a technique owning ordered `technique_stages`, each owning ordered `technique_phases` — three levels, and the naive traversal is three round trips per technique. Check that the list path fetches the set and groups in memory rather than walking the tree.
- The fix is a batch query (`WHERE … = ANY($1)`) or a join, followed by grouping in the service. Note that grouping through a `HashMap` loses insertion order, which is why `phase_order_follows_ordinal_not_insertion_order` exists — propose the batch fix _and_ the explicit sort.

### Missing Indexes

- `WHERE` and `ORDER BY` on columns with no index. Cross-reference `crates/migrate/migrations/` for what exists.
- The per-person tables are the ones that grow without bound: journey entries, sessions, quota rows. A query filtering on a user id needs that index long before the table is big enough to notice.
- Foreign keys are not automatically indexed in Postgres. A child table queried by parent id (`technique_stages.technique_id`) needs one declared.

### Unbounded Queries

- Queries with no `LIMIT` that could return an unbounded set. The technique catalogue is curated and small — it is fine. Anything per-person is not: a journey list that returns every entry a user has ever recorded gets slower every day they use the app.
- List RPCs with no pagination in the contract at all. Adding it later is a breaking proto change, so flag it while the surface is still small.
- `SELECT *` (or a `query_as!` selecting columns nothing reads) where a narrow projection would do.

### Transactions and Connections

- A transaction held open across an `.await` on something slow — an external call, or the model provider.
- A connection acquired from the pool and held for the duration of a request rather than per query.

**Severity guide:**

- N+1 on a list path → Warning
- Unbounded query on a per-person table that grows over time → Warning
- Transaction held open across an external call → Warning
- Missing index on a frequently-filtered column or an unindexed foreign key → Suggestion
- Over-wide projection → Suggestion

---

## 2. Rust Performance

**What to check:**

### Blocking in Async

- Blocking file I/O, synchronous HTTP, or CPU-heavy work on the runtime without `spawn_blocking`.
- `std::thread::sleep` in async code — use `tokio::time::sleep`.
- A `std::sync::Mutex` guard held across an `.await`. The workspace lints already warn on this (`await_holding_lock`, and `significant_drop_tightening`), and the `Cargo.toml` comment says why it is the one that actually bites: it deadlocks the executor rather than failing loudly. So the finding here is an `#[allow]` hiding it, or a pattern the lint cannot see — a guard moved into a struct that then crosses an await.

### Allocation and Cloning

- `.clone()` on large values in a loop or on a request path. `redundant_clone` is warned, so look for the ones it misses: cloning a `Vec` to satisfy a borrow that a lifetime would solve, cloning an `Arc`'s contents rather than the `Arc`.
- `.collect::<Vec<_>>()` immediately followed by `.iter()`.
- `format!` building a string only to pass it to a structured log field that accepts a reference.

### Streaming

- The one streaming RPC accumulates a response. Check that chunks are forwarded as they arrive rather than buffered into a `String` and sent at the end — a stream that only yields once has the cost of streaming with none of the benefit, and `docs/transport.md` notes the rule-based fallback is deliberately split into paragraphs so the client's accumulate-and-render path is the only path.

**Severity guide:**

- Blocking I/O or CPU-bound work on the async runtime without `spawn_blocking` → Warning
- Sync mutex guard held across an await, behind an `#[allow]` or invisible to the lint → Warning
- A "stream" that buffers fully before sending → Warning
- Excessive cloning of a large value on a request path → Suggestion
- Unnecessary intermediate allocation → Suggestion

---

## 3. SwiftUI Performance

**What to check:**

### Body Recomputation

- Expensive work inside `body` — sorting, filtering, date formatting, or constructing a `DateFormatter` (which is expensive and belongs in a `static let`). `body` runs on every state change.
- Observable state whose granularity is too coarse: a single `@Observable` model driving a whole screen re-renders everything when one field changes. Split when a hot field (an animation phase, a countdown) sits alongside cold ones.
- `@State` initialised from a computed value that re-runs on every init.

### The Session Loop

The breathing session is the app's hot path: a timer driving an animated wheel, haptics, and audio, for minutes at a time. Check it specifically.

- A per-tick `Timer` or `TimelineView` cadence finer than the animation needs — a 60 Hz tick driving a wheel that changes on phase boundaries is battery spent for nothing.
- State published on every tick that causes an unrelated view to re-render.
- Work on the main actor per tick — file writes, encoding, a network call.
- Haptics and audio scheduled per-frame rather than per-phase.

### Lists and Data

- A `List`/`ForEach` over a collection that grows without bound (journey history) with no paging.
- `ForEach` without a stable `id`, forcing SwiftUI to rebuild rows.
- Repeated decoding or file reads on view appearance where a cached value exists. The catalogue is cached offline-first — check the cache is actually consulted before the network, not after.

### Concurrency

- `Task` created in `body` or `onAppear` without cancellation on disappear — a repeated navigation stacks orphaned work.
- Main-actor work that does not need to be there: JSON decode, keychain access, disk writes.

**Severity guide:**

- Per-tick main-actor work (disk, encode, network) in the session loop → Warning
- `Task` in `onAppear` with no cancellation → Warning
- Unbounded list with no paging → Warning
- Expensive derivation or formatter construction inside `body` → Suggestion
- `ForEach` without a stable id → Suggestion
- Over-coarse observable state on the session path → Suggestion

---

## 4. Resource Lifecycle

**What to check:**

- **Audio session.** Activated and never deactivated, or left active when the session ends — it takes the device out of silent behaviour and keeps other audio ducked.
- **Haptic engine.** Started per session and not stopped, or restarted per phase.
- **Background tasks and timers.** A timer that keeps firing when the app backgrounds, or a session that silently stops because nothing asked to continue.
- **Watch connectivity.** A session activated once versus per message; observers registered and never removed.
- **Rust side.** File handles or connections not released on the error path.

**Severity guide:**

- Audio session or haptic engine left active after a session ends → Warning
- Timer still firing in the background with nothing consuming it → Warning
- Observer registered with no matching removal → Warning
- Resource released only on the success path → Warning

---

## 5. Accessibility

This is an app people use with their eyes closed, in the dark, while regulating their breathing. Accessibility here is not a compliance checkbox — it is the primary interaction mode for a real share of the sessions.

**What to check:**

### Reduce Motion

- The breathing wheel and any expanding/contracting animation must respect `@Environment(\.accessibilityReduceMotion)`. When it is on, the guidance still has to be conveyable — a static indicator with a phase label, or a crossfade instead of continuous motion. An animation that ignores the setting can cause nausea in exactly the population most likely to reach for a breathing app.
- `withAnimation` calls on the session path with no reduce-motion branch.

### VoiceOver

- Every control has a label. Icon-only buttons (play, pause, skip, close) with no `accessibilityLabel` are announced as "button".
- The wheel and other custom-drawn views need `accessibilityLabel` plus a `accessibilityValue` that changes with the phase, or they are an unlabelled image to a screen-reader user.
- Decorative shapes need `.accessibilityHidden(true)`, or VoiceOver walks through the scenery.
- Phase transitions during a session should announce — `AccessibilityNotification.Announcement` or an `accessibilityValue` that updates — otherwise the whole session is silent to VoiceOver.
- Grouped content: a technique card whose title, summary, and duration are three separate stops should be `.accessibilityElement(children: .combine)`.

### Dynamic Type

- Fixed font sizes (`.font(.system(size: 17))`) instead of text styles, which do not scale.
- Fixed-height containers holding text — at accessibility sizes the text truncates or clips. Check `frame(height:)` around labels.
- Layouts that break at the largest sizes: side-by-side content that should stack via `@Environment(\.dynamicTypeSize)` or a `ViewThatFits`.

### Colour and Contrast

- Information carried by colour alone. `BreatheUI` exposes accents named for feeling (`settle`, `night`, `spark`, `restore`) and features map goals onto them — if the accent is the only thing distinguishing two goals, that distinction does not exist for a colour-blind user. It needs a label or a shape too.
- Text on accent backgrounds meeting WCAG AA (4.5:1 normal, 3:1 large). The dark palette is where this usually fails.
- `.accessibilityDifferentiateWithoutColor` unhandled where colour is doing semantic work.

### Touch Targets and Focus

- Interactive elements below the 44×44pt minimum.
- Focus not moving to newly presented sheets and alerts.
- Custom gestures with no accessible alternative — a swipe-only action is unreachable via VoiceOver unless it has an `accessibilityAction`.

**Severity guide:**

- Session animation ignoring Reduce Motion → Warning
- Icon-only control with no accessibility label → Warning
- The wheel exposed to VoiceOver with no label or changing value → Warning
- Fixed font size or fixed-height text container breaking Dynamic Type → Warning
- Information conveyed by accent colour alone → Warning
- Touch target below 44×44pt → Suggestion
- Decorative view not hidden from VoiceOver → Suggestion
- Missing focus move on sheet presentation → Suggestion
