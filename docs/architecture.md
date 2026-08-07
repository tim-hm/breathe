# Architecture

## Shape

```text
┌──────────────────────────────┐
│  ios/  SwiftUI apps          │
│    Breathe      (iOS)        │
│    OndWatch (watchOS)    │
│    └── OndCore           │  one SwiftPM package, three targets
│        ├── OndKit        │  domain models + repositories
│        │   └── OndAPI    │  generated protobuf + Connect client
│        └── OndUI         │  design tokens
└───────────┬──────────────────┘
            │  gRPC-Web (binary protobuf over HTTP POST)
┌───────────▼──────────────────┐
│  crates/api                  │  axum (JSON) + tonic (gRPC-Web), one port
│    features/technique/       │  handler → service → repository
│    features/profile/         │
│    features/journey/         │
│    features/assistant/       │
│    features/entitlement/     │
└───────────┬──────────────────┘
            │  sqlx, compile-time-checked queries
┌───────────▼──────────────────┐
│  PostgreSQL 18               │  schema owned by crates/migrate
└──────────────────────────────┘

proto/  ──────────────────►  generates both ends
web/    ──────────────────►  the one-pager, served from the same hostname
infra/  ──────────────────►  the box all of the above is deployed onto
```

Both apps sit on the same two products. What they share and what they deliberately duplicate is in [code-structure.md](code-structure.md).

## Components

| Component                  | Role                                                                                                                     |
| :------------------------- | :----------------------------------------------------------------------------------------------------------------------- |
| `proto/`                   | The API contract. The only description of the wire format.                                                               |
| `crates/api`               | The service. Serves gRPC-Web on `/ond.v1.*` and JSON on `/health`, `/about`.                                             |
| `crates/migrate`           | Owns the schema and the seeded technique catalogue. Runs to completion and exits.                                        |
| `…/OndCore/Sources/OndAPI` | Generated protobuf and the Connect client factory. Not a package product, so only OndKit can reach it.                   |
| `…/OndCore/Sources/OndKit` | Domain types, observable models, and repositories. The only Swift code that touches generated types.                     |
| `…/OndCore/Sources/OndUI`  | Spacing and accent tokens. Domain-free.                                                                                  |
| `ios/Breathe`              | The iOS app: composition root plus features.                                                                             |
| `ios/OndWatch`             | The watchOS app: the same session over the same package, plus the `WatchConnectivity` link that hands it an identity.    |
| `web/`                     | The marketing one-pager. Two static files, no build step — Caddy serves them beside the API on one hostname.             |
| `infra/`                   | OpenTofu for the single box everything above is deployed onto, plus what runs on it. See [deployment.md](deployment.md). |

### Backend features

Each is `crates/api/src/features/<name>/`, laid out handler → service → repository. Only the first is readable without an identity.

| Feature       | Role                                                                                                                                  |
| :------------ | :------------------------------------------------------------------------------------------------------------------------------------ |
| `technique`   | The catalogue: techniques, the stages and phases they play, and the breathing foundations served alongside them.                      |
| `profile`     | What onboarding collected, from goals down to the display name a leaderboard prints.                                                  |
| `journey`     | Sessions, controlled-pause scores, streaks, and leaderboards — all derived on read from two append-only tables.                       |
| `assistant`   | A language model reading the profile and the catalogue, and the rules that answer when it cannot. The only feature that spends money. |
| `entitlement` | App Store transactions verified against Apple's chain, stored as the tier and expiry `assistant` gates on.                            |

## Decisions worth knowing

**PostgreSQL enums, not text columns.** `technique_goal` and `phase_kind` are native enums. The proto contract already fixes both value sets, so the database rejecting a fifth value at write time is strictly better than it reaching a client as something unmapped.

**Stages and phases are child tables.** A technique owns ordered `technique_stages`, and each stage owns ordered `technique_phases` — both keyed on `(…, ordinal)` rather than held as a JSON column on `techniques`. The session is queried as a set and its shape is fixed by the contract; JSON would buy schema flexibility this data does not want, at the cost of the ordering guarantee the keys provide for free. A plain cyclic technique is one stage; the Wim Hof-style protocol, where a retention the person ends sits between fast breaths and a recovery hold, is why the level exists at all.

**The catalogue lives in code.** `crates/migrate/src/seed.rs` holds the nine techniques and the breathing foundations, and reconciles them into the database on every run. They are curated reference data, not user content — editing a summary there and re-running `mise run migrate` is the supported way to change one.

**No `shared` crate.** With one service there is no second consumer, so there is nothing to share. Create it when a second crate genuinely needs a type, not before.

**Identity is possession of a UUID.** The client mints one on first launch, keeps it in the Keychain so it survives a reinstall, and sends it as the `ond-user-id` header on every RPC. `crates/api/src/identity.rs` resolves it as middleware — the file's `//!` has the three outcomes and [transport.md](transport.md) has where the layer sits in the stack and why. `profile`, `journey`, `entitlement` and `assistant` all require it; `TechniqueService` deliberately does not, because gating the catalogue would gate the app's first screen on a Keychain write.

There is no token and no signature: possession of the id is the whole claim. That is the trade V1 makes — anonymous, no account, nothing sensitive stored — and it is why `users.apple_user_id` exists as a column nothing writes to yet. Sign in with Apple attaches a real credential there without moving anything else.

**The catalogue's paid tier is advisory.** `ListTechniques` takes no identity and returns every technique whole, with `requires_subscription` as one boolean per row that nothing server-side enforces. A session runs entirely on the device, so a gate here would withhold nothing it costs anything to serve; what does cost money is the language model, and `entitlement` guards that one against the caller's own row. The field's zero value is deliberately _unlocked_ for the same reason, argued at the field itself in `proto/ond/v1/technique_service.proto`. Genuinely withholding the catalogue would mean a second RPC serving full detail only to entitled callers, with `ListTechniques` cut back to name and summary for locked rows — take that only if the catalogue's breadth becomes the product.

## What runs where

Locally, only PostgreSQL is containerised (`compose.yaml`); the API runs natively under `mise run dev` so a code change rebuilds in seconds. [contributing.md](contributing.md) is the whole of that surface.

Deployed, everything is containerised on one box provisioned by OpenTofu from `infra/`: the API, Postgres, and a Caddy that fronts both the RPC surface and `web/`. There is still no Kubernetes and no Tilt — one box is the deliberate ceiling for V1, and [deployment.md](deployment.md) has the topology and, more usefully, where each of its decisions runs out.
