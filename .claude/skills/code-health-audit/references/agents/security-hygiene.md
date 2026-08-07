# Security & Hygiene — Review Reference

You are reviewing the codebase for security: identity and ownership, input validation, the model-provider surface, secrets, and dependency hygiene.

Use finding ID prefix: **SEC**

---

## 1. Identity and Ownership

Read `crates/api/src/identity.rs` before anything else in this section. Its module doc states the whole model, and the review only makes sense against it:

> A client generates a UUID on first launch, keeps it in its Keychain, and sends it on every RPC. Possession of the id _is_ the claim — there is no token, no signature, and nothing here pretends otherwise. That is a deliberate trade for V1 (anonymous, no account, nothing sensitive stored), and the `users.apple_user_id` column is where a real credential attaches when Sign in with Apple lands.

So "there is no authentication" is not a finding — it is the design. What _is_ a finding is anything that leans on the id being harder to obtain than it is, or that bypasses the one control the model does have: the middleware resolves the caller and injects `UserId`, and every per-person path must read it from there.

**What to check:**

### Ownership (the highest-value check here)

- **A user identifier taken from the request message.** Any RPC field that names whose data to read or write — `user_id`, `owner_id`, an id embedded in a composite key — lets a caller name someone else. The identity must come from the `UserId` request extension the middleware injected, never from the body. This is the IDOR shape and it is Critical wherever it appears.
- **A per-person query with no user predicate.** Every `SELECT`, `UPDATE`, and `DELETE` against a per-person table (profiles, journey entries, sessions, quota, entitlements) must be scoped by user id in the `WHERE` clause. A `DELETE … WHERE id = $1` with no ownership term deletes any row whose id a caller can guess.
- **A handler on a per-person service that tolerates a missing `UserId`.** The middleware deliberately passes through when no header is sent, because the technique catalogue is public reference data and gating the app's first screen on a Keychain write would be wrong. That pass-through is correct for `TechniqueService` and wrong for everything that touches a person's data — a handler that defaults, falls back to anonymous, or silently no-ops instead of returning `UNAUTHENTICATED` is a hole.
- **New per-person surfaces.** Cross-reference the heat map and the migration list. A new table with a `user_id` column, or a new RPC on an existing per-person service, is where this class of bug lands. Check each one individually.

### Leakage of the id

Possession is the claim, so the id is a bearer credential in everything but name, and the review should treat it as one.

- It must never appear in a response to a _different_ caller — in a list, an error message, or a shared object.
- It must never be embedded in something exportable: a share sheet, a URL, a QR code, an exported file, a support bundle.
- Client-side, it lives in the Keychain (`KeychainIdentityItem`), not `UserDefaults`. Check the accessibility attribute is still `kSecAttrAccessibleAfterFirstUnlock` or stricter, and that the item is not marked synchronizable unless syncing it across a person's devices is the intent — an iCloud-synced bearer credential has a different threat model than a device-local one, and that decision should be explicit.

### Transport

- The gRPC-Web CORS policy is the boundary between the browser origin model and this API. `cors_layer` exists to expose `grpc-status` and `grpc-message`; check it has not grown a permissive `allow_origin(Any)` alongside credentials, and that the identity header is allowed rather than the allow-list being widened to everything.

**Severity guide:**

- A user identifier read from the request message rather than the `UserId` extension → Critical
- A per-person query with no ownership predicate → Critical
- A per-person handler that proceeds when `UserId` is absent → Critical
- The user id exposed to another caller or into an exportable artefact → Critical
- Keychain item weakened (looser accessibility, or synchronizable without intent) → Warning
- CORS widened beyond what gRPC-Web needs → Warning

---

## 2. Input Validation

**What to check:**

### RPC inputs

- Every field of an incoming proto message is attacker-controlled, and proto3 gives every scalar a zero value the wire can always produce. Check that `service.rs` validates before use: string lengths bounded, enums converted through an explicit `match` with no catch-all, numeric ranges checked, collections size-limited.
- Unbounded strings reaching the database or the model provider. A free-text field with no length cap is both a storage problem and a cost problem.
- Validation belongs in `service.rs` per the layering contract, not in the repository and not left to a database constraint alone. A constraint that fails produces an opaque `internal` status rather than a useful `invalid_argument`.

### SQL

- `sqlx::query!` / `query_as!` / `query_scalar!` are compile-time checked against the real schema and parameterise their arguments. Anything else is the finding: `sqlx::query(&format!(…))`, a `String` built with user input and passed to `query`, or the `_unchecked` macro variants, which drop the schema check.
- Dynamic SQL that must be built at runtime (sort column, filter set) must come from a closed enum, never from a caller-supplied string.

### Other vectors

- **SSRF** — a caller-supplied URL reaching an HTTP client. The provider base URL is derived in `config.rs` by convention, and it should stay derived; a request field that can redirect the model call is a serious finding.
- **Path traversal** — user input in a file path, in the Rust side or in the Swift file stores (`JSONFileStore` and friends). A cache filename built from a server-supplied slug is the shape to check.
- **Command execution** — nothing in this repo should be shelling out. If something does, that is the finding before the injection is.

**Severity guide:**

- SQL built by string interpolation with caller-supplied input → Critical
- A caller-supplied value reaching a URL the server then fetches → Critical
- User input in a file path with no sanitisation → Critical
- Unbounded string accepted from an RPC and stored or forwarded → Warning
- Enum converted with a catch-all arm instead of an explicit `match` → Warning
- Validation deferred from `service.rs` to a database constraint → Suggestion

---

## 3. The Model-Provider Surface

The assistant sends text a person wrote to a third party and renders what comes back. Both directions need review, and this is the newest surface in the repo.

**What to check:**

### Untrusted output

- **Model output must not be trusted as data.** `only_real_slugs_reach_the_client` exists because a model naming a technique that does not exist must not be able to put that name in front of anyone. Check that _every_ structured field the model produces is validated against something authoritative — the seeded catalogue, an enum, a known id set — before it reaches a response. A new field added to the assistant's output without a matching validation is a finding even though nothing has gone wrong yet.
- Output rendered as markup, a link, or anything the app will act on rather than display as text.

### Untrusted input

- **Prompt injection.** User text is concatenated into a prompt. The mitigation is not sanitising the text — it is that nothing downstream trusts the output (above). Flag any place where model output is granted authority: choosing what to store, deciding an entitlement, selecting a database row by a name the model produced.
- User text forwarded to the provider without a length cap.

### Cost and availability controls

- **Server-side enforcement.** The spend ceiling and the circuit breaker are the controls that stop a bad day from becoming an unbounded bill. Both must be enforced on the server, per user, before the provider call. A quota checked in the app, or checked after the call, is not a control. `an_exhausted_quota_answers_from_the_rules` and `the_breaker_trips_and_then_recovers` pin the current behaviour — check any new provider call path goes through the same gate rather than around it.
- **Absent-key behaviour.** `CLAUDE.md` §1.4 says the assistant answers from its rule-based fallback when `OPENROUTER_API_KEY` is absent. Check that path degrades rather than erroring, and that it does not leak the reason to the client.
- Timeouts on the provider call. An unbounded upstream hold is a resource exhaustion vector with no attacker required.

**Severity guide:**

- A structured model output used to select or name a real resource with no validation → Critical
- Model output granted authority over storage, entitlement, or a database lookup → Critical
- Quota or breaker enforced client-side, or checked after the provider call → Critical
- A provider call path that bypasses the quota gate → Warning
- No timeout on the provider call → Warning
- Unbounded user text forwarded to the provider → Warning

---

## 4. Entitlements

`entitlement` is per-person state that decides what someone is allowed to do, which makes it the highest-consequence ownership surface in the repo.

**What to check:**

- The entitlement is resolved server-side from the caller's `UserId`, never asserted by the client. A request field declaring "I am a subscriber" is the finding.
- If a store receipt or transaction id is involved, it is verified against the store, not trusted as submitted, and a receipt is bound to one user — a replayed receipt must not grant a second person access.
- Entitlement checks happen before the gated work, not after, and not only in the app's UI.
- Expiry and revocation are evaluated at use time, not cached indefinitely.

**Severity guide:**

- Entitlement taken from the request rather than resolved from `UserId` → Critical
- Store receipt trusted without verification, or replayable across users → Critical
- Gated work performed before the entitlement check → Critical
- Entitlement cached with no expiry evaluation → Warning

---

## 5. Secrets & Credentials

**What to check:**

- **No secrets in source.** Strings shaped like API keys, base64 blobs, `password = "…"`, connection strings with credentials. Check test files too — test secrets must be obviously fake.
- **`.env` is gitignored** (`.gitignore:25`) and must not be tracked. Verify with `git ls-files` rather than assuming, and check the same for `*.pem`, `*.key`, `*.p8` (the App Store connect key shape), and anything under `infra/` holding state or credentials.
- **The three-variable rule.** `CLAUDE.md` §1.4: the backend reads `BREATHE_ENV`, `DATABASE_URL`, and the optional `OPENROUTER_API_KEY`, and nothing else. A fourth is a config value that can differ between a laptop and a deployment without anything noticing — which is a correctness problem before it is a security one, but it is often both.
- **No default value for a secret.** A fallback that is a real key is the worst case; a fallback that is a placeholder which then _works_ against something is nearly as bad.
- **`Debug` derives on structs holding secrets.** A `#[derive(Debug)]` on a config struct containing the API key prints it the first time anything logs that struct.
- **Deployment configuration.** Check `infra/` and `Dockerfile` for a secret baked into an image layer or a Terraform variable with a committed default.

**Severity guide:**

- Hardcoded secret or credential in source → Critical
- A credential file tracked in git → Critical
- Secret baked into an image layer or committed as an infrastructure default → Critical
- `Debug` derive on a type holding a secret → Warning
- A fourth environment variable read by the backend → Warning
- Real-looking credential in a test file → Warning

---

## 6. Dependency Hygiene

**What to check:**

- **Lock files committed.** `Cargo.lock` and `Package.resolved` must be tracked and must not be gitignored. `docs/code-structure.md` explains why the Swift package graph is one package rather than three: several `Package.resolved` files would be free to pin different versions of the same dependency. A second package appearing is a supply-chain concern as well as a structural one.
- **Known vulnerabilities.** There is no `cargo audit` mise task and no Dependabot-equivalent in `.github/workflows/checks.yml` — say so if you find it still true, because "nobody is watching the advisory feed" is a standing finding, not a code one. Do not run the audit yourself.
- **Unused dependencies.** `mise run check:deps` covers this; check it is still in the `check` chain rather than re-deriving it by hand.
- **Toolchain pins.** `.mise.toml`'s `[tools]` section fixes the toolchain both languages build against. A pin that has drifted far behind is a security-relevant staleness, not a style one.
- **New dependencies in the window.** From the scoping data: for each new dependency, ask whether it earns its attack surface, and whether it pulls in a transitive tree disproportionate to what it does.

**Severity guide:**

- A lock file untracked or gitignored → Critical
- Known critical vulnerability in a production dependency → Critical
- No mechanism watching for advisories → Warning
- Significantly outdated security-relevant dependency or toolchain pin → Warning
- Unused dependency → Suggestion
