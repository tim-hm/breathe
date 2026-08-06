# Architecture

## Shape

```text
┌──────────────────────────┐
│  ios/  SwiftUI app       │
│    Breathe (app target)  │
│    └── BreatheCore       │  one SwiftPM package, three targets
│        ├── BreatheKit    │  domain models + repositories
│        │   └── BreatheAPI│  generated protobuf + Connect client
│        └── BreatheUI     │  design tokens
└───────────┬──────────────┘
            │  gRPC-Web (binary protobuf over HTTP POST)
┌───────────▼──────────────┐
│  crates/api              │  axum (JSON) + tonic (gRPC-Web), one port
│    features/technique/   │  handler → service → repository
└───────────┬──────────────┘
            │  sqlx, compile-time-checked queries
┌───────────▼──────────────┐
│  PostgreSQL 18           │  schema owned by crates/migrate
└──────────────────────────┘

proto/  ──────────────────►  generates both ends
```

## Components

| Component                          | Role                                                                                                       |
| :--------------------------------- | :--------------------------------------------------------------------------------------------------------- |
| `proto/`                           | The API contract. The only description of the wire format.                                                 |
| `crates/api`                       | The service. Serves gRPC-Web on `/breathe.v1.*` and JSON on `/health`, `/about`.                           |
| `crates/migrate`                   | Owns the schema and the seeded technique catalogue. Runs to completion and exits.                          |
| `…/BreatheCore/Sources/BreatheAPI` | Generated protobuf and the Connect client factory. Not a package product, so only BreatheKit can reach it. |
| `…/BreatheCore/Sources/BreatheKit` | Domain types and repositories. The only Swift code that touches generated types.                           |
| `…/BreatheCore/Sources/BreatheUI`  | Spacing and accent tokens. Domain-free.                                                                    |
| `ios/Breathe`                      | The app: composition root plus features.                                                                   |

## Decisions worth knowing

**PostgreSQL enums, not text columns.** `technique_goal` and `phase_kind` are native enums. The proto contract already fixes both value sets, so the database rejecting a fifth value at write time is strictly better than it reaching a client as something unmapped.

**Stages and phases are child tables.** A technique owns ordered `technique_stages`, and each stage owns ordered `technique_phases` — both keyed on `(…, ordinal)` rather than held as a JSON column on `techniques`. The session is queried as a set and its shape is fixed by the contract; JSON would buy schema flexibility this data does not want, at the cost of the ordering guarantee the keys provide for free. A plain cyclic technique is one stage; the Wim Hof-style protocol, where a retention the person ends sits between fast breaths and a recovery hold, is why the level exists at all.

**The catalogue lives in code.** `crates/migrate/src/seed.rs` holds the nine techniques and the breathing foundations, and reconciles them into the database on every run. They are curated reference data, not user content — editing a summary there and re-running `mise run migrate` is the supported way to change one.

**No `shared` crate.** With one service there is no second consumer, so there is nothing to share. Create it when a second crate genuinely needs a type, not before.

**No auth.** The technique catalogue is public reference data. The next feature that stores anything per-person — saved sessions, streaks, HealthKit sync — needs an identity model, and that is the point at which to design one rather than retrofit it around this slice.

## What runs where

Locally, only PostgreSQL is containerised (`compose.yaml`); the API runs natively under `mise run dev` so a code change rebuilds in seconds. There is no Kubernetes, no Tilt, and no deployment target yet — [contributing.md](contributing.md) is the whole operational surface.
