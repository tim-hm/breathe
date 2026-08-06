# Contributing

## Prerequisites

- **[mise](https://mise.jdx.dev)** — installs and pins every other tool. Nothing else needs installing by hand.
- **Docker** (OrbStack or Docker Desktop) — runs PostgreSQL, and nothing else.
- **Xcode** — required for the iOS app. The Command Line Tools alone are not enough.

### Point the toolchain at Xcode (one time, required)

Installing Xcode does not change the active developer directory. Until you switch it, `swiftlint` fails to load `sourcekitd` and Swift Testing is missing entirely — both with errors that look like broken configuration rather than a missing toolchain:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch     # accepts the licence, installs components
```

Verify with `xcode-select -p`; it should print the Xcode path, not `/Library/Developer/CommandLineTools`.

## First run

```bash
mise install          # every pinned tool
mise run migrate      # starts Postgres, creates the DB, migrates, seeds
mise run dev          # API on :18100
```

In another terminal:

```bash
curl -s localhost:18100/health
grpcurl -plaintext localhost:18100 breathe.v1.TechniqueService/ListTechniques
```

Then the app:

```bash
mise run ios:open     # generates Breathe.xcodeproj and opens it
```

Pick any iPhone simulator and press ⌘R. You should see four techniques, served from your local Postgres.

## Ports

| Service | Port | Notes |
| :-- | :-- | :-- |
| API | 18100 | gRPC-Web and JSON on the same listener |
| PostgreSQL | 18101 | `mise run db:psql` to query it |

**breathe owns 18100–18199.** Every port this repo uses comes from that block, and nothing else on the machine should claim it — one range means one thing to remember and one thing to check.

The block is chosen to clear the sibling `connect` repo, which reserves 15432, 15433, 17233, 17474, 17687, 18080–18092, and 19000. That matters more than it sounds: connect's Tilt binds `127.0.0.1:15432`, which beats a container's `*:15432` binding for anything resolving `localhost`, so a breathe process pointed at 15432 would silently read and write connect's database. If you add a service, take the next free number in 18100–18199.

## The gate

```bash
mise run generate   # 1. protobuf types + SQLx cache
mise run fmt        # 2. format
mise run check      # 3. full validation
```

`mise run check` covers Rust, protobuf, markdown, and doc links. It deliberately excludes `check:swift` and `test:swift`, which need the Xcode toolchain — run those yourself when touching `ios/`.

## Common tasks

| Intent | Command |
| :-- | :-- |
| Wipe and rebuild the database | `mise run dev:db:reset` |
| Query the database | `echo 'select * from techniques;' \| mise run db:psql` |
| Change the technique catalogue | Edit `crates/migrate/src/seed.rs`, then `mise run migrate` |
| Change the API contract | Edit `proto/breathe/v1/…`, then `mise run generate` |
| Add a Swift file | Create it under `ios/Breathe/`; `mise run ios:gen` picks it up |
| Build the app headlessly | `mise run ios:build` |

## Things that will bite you

**A stale `DATABASE_URL` in your shell.** If you have used the `connect` repo in the same terminal, `DATABASE_URL` is exported and points at its database. Running `cargo run -p migrate` directly then targets the wrong cluster; sqlx aborts before applying anything, but the error is confusing. Always go through `mise run`, which supplies its own.

**The Xcode project is generated.** `ios/Breathe.xcodeproj` is gitignored and rebuilt from `ios/project.yml`. Changing build settings in Xcode's UI works until the next `mise run ios:gen` throws it away — make the change in `project.yml` instead.

**Regenerated Swift is committed.** After editing a `.proto`, `mise run generate:proto` rewrites files under `ios/Packages/BreatheCore/Sources/BreatheAPI/Generated/`. Commit them; the Xcode build does not run `buf`.

**Postgres 18 moved its data directory.** The compose volume mounts `/var/lib/postgresql`, not `/var/lib/postgresql/data`. Copying a volume line from an older project makes the container refuse to start with a long, easily-misread explanation.
