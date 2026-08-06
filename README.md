# breathe

A minimalist iOS app for breathing techniques — to calm down, get to sleep, find energy, or reset after a spike.

A native SwiftUI client, a Rust backend, and PostgreSQL, sharing one Protobuf contract.

```bash
mise install        # every pinned tool
mise run migrate    # Postgres up, schema applied, catalogue seeded
mise run dev        # API on :18100
mise run ios:open   # generate the Xcode project and open it
```

Full setup, including the one-time `xcode-select` step, is in [docs/contributing.md](docs/contributing.md).

## Layout

```text
proto/     the API contract — generates both the Rust server and the Swift client
crates/    api (axum + tonic) and migrate (schema + seed)
ios/       SwiftUI app over BreatheKit, BreatheAPI, and BreatheUI
docs/      start at docs/README.md
```

Conventions and the task graph are in [CLAUDE.md](CLAUDE.md).
