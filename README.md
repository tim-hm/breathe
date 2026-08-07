# breathe

A minimalist iOS app for breathing techniques — to calm down, get to sleep, find energy, or reset after a spike.

Native SwiftUI clients for iPhone and Apple Watch, a Rust backend, and PostgreSQL, sharing one Protobuf contract.

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
ios/       iPhone and Apple Watch apps over OndKit and OndUI
web/       the marketing one-pager, served beside the API
infra/     OpenTofu and the compose stack the deployment runs
docs/      start at docs/README.md
```

Conventions and the task graph are in [CLAUDE.md](CLAUDE.md).
