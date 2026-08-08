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
grpcurl -plaintext localhost:18100 ond.v1.TechniqueService/ListTechniques
```

Then the app:

```bash
mise run ios:open     # generates Ond.xcodeproj and opens it
```

Pick any iPhone simulator and press ⌘R. You should see nine techniques, served from your local Postgres.

## Ports

| Service    | Port  | Notes                                     |
| :--------- | :---- | :---------------------------------------- |
| API        | 18100 | gRPC-Web and JSON on the same listener    |
| PostgreSQL | 18101 | `mise run db:psql` to query it            |
| `web/`     | 18102 | `mise run web:serve`, static preview only |

**önd owns 18100–18199.** Every port this repo uses comes from that block, and nothing else on the machine should claim it — one range means one thing to remember and one thing to check.

The block is chosen to clear the sibling `connect` repo, which reserves 15432, 15433, 17233, 17474, 17687, 18080–18092, and 19000. That matters more than it sounds: connect's Tilt binds `127.0.0.1:15432`, which beats a container's `*:15432` binding for anything resolving `localhost`, so an önd process pointed at 15432 would silently read and write connect's database. If you add a service, take the next free number in 18100–18199.

## The gate

```bash
mise run generate   # 1. protobuf types + SQLx cache
mise run fmt        # 2. format
mise run check      # 3. full validation
```

`mise run check` covers Rust, protobuf, doc links, and the formatting of everything that is not Rust or Swift — markdown, YAML, JSON, and TOML all go through `vp` (`check:text`), with `check:md` layering markdown's own rules on top. It deliberately excludes `check:swift` and `test:swift`, which need the Xcode toolchain — run those yourself when touching `ios/`.

### Breaking the protobuf contract on purpose

`check:proto` compares `proto/` against `main` and fails on a breaking change, because a released client would break with it. Until one has shipped there is nothing to protect, and a contract that cannot be corrected before its first release is worse than one that can — replacing `Technique.phases` with `stages` was taken for exactly that reason, while no released client existed to break.

The single-run override:

```bash
PROTO_BREAKING_ACK='replaces Technique.phases with stages; no client has shipped' mise run check
```

It is per-invocation, it still runs `buf breaking` and prints every finding, and it asks for a sentence rather than a flag. Nothing about it persists: once the commit is on `main` the comparison is against the new shape and the check passes unaided, so reaching for this twice in a row means the first break was never merged — or that the contract now has clients and the change needs a new field instead.

CI (`.github/workflows/checks.yml`) runs the formatting and lint subset on every push to `main` and every pull request: `check:rs`, `check:proto`, `check:text`, `check:md`, and `check:doc-links` on Linux, plus `check:swift` on macOS. Tests and the drift checks (`check:sqlx`, `check:generated`) remain local — CI has neither a database nor BSR access — so the full gate is still `mise run check` before committing.

## Common tasks

| Intent                          | Command                                                                       |
| :------------------------------ | :---------------------------------------------------------------------------- |
| Wipe and rebuild the database   | `mise run dev:db:reset`                                                       |
| Query the database              | `echo 'select * from techniques;' \| mise run db:psql`                        |
| Try the coach against the model | `mise run dev:coach [user-id]`                                                |
| Change the technique catalogue  | Edit `crates/migrate/src/seed.rs`, then `mise run migrate`                    |
| Change the API contract         | Edit `proto/ond/v1/…`, then `mise run generate`                               |
| Add a Swift file                | Create it under `ios/Ond/` or `ios/OndWatch/`; `mise run ios:gen` picks it up |
| Build the apps headlessly       | `mise run ios:build`, `mise run ios:build:watch`                              |
| Ship a beta                     | `mise run ios:testflight` — see below                                         |

## Releasing to TestFlight

One archive carries both apps: the phone target embeds the watch app, and a companion watch app is not a submission of its own.

```bash
mise run ios:archive      # signed archive in ios/build/Ond.xcarchive
mise run ios:testflight   # archives, re-signs for distribution, uploads
```

Three values, all machine-local and all in `.env`, which `.mise.toml` loads:

| Variable            | What it is                                                                |
| :------------------ | :------------------------------------------------------------------------ |
| `OND_DEV_TEAM`      | the ten-character Apple Developer team id, substituted into `project.yml` |
| `OND_ASC_KEY_ID`    | App Store Connect API key id                                              |
| `OND_ASC_ISSUER_ID` | that key's issuer id                                                      |

The key's `.p8` is a file rather than a value and never goes in `.env`: put it at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`, the path Apple's own tooling searches, which is why only the id is configured. Create the key under **Users and Access → Integrations → App Store Connect API** with the **Admin** role — App Manager can upload but cannot mint the distribution certificate the first export needs — and note that the `.p8` downloads exactly once.

Both tasks refuse with an explanation rather than a signing error when something is missing, so running them is the fastest way to find out what you still need.

Two things the tasks decide for you. The **build number is the commit count** (`git rev-list --count HEAD`), because App Store Connect refuses a number it has already accepted; two archives of the same commit collide, and the answer to that is a commit. The **version** is `MARKETING_VERSION` in `project.yml`, set at project level so the watch app cannot disagree with its host — a mismatch fails validation.

Xcode signs the archive itself with the _development_ certificate; distribution signing is applied when `ios:testflight` exports it. That is why an archive is worth taking on a machine that has no distribution certificate yet.

## Things that will bite you

**A stale `DATABASE_URL` in your shell.** If you have used the `connect` repo in the same terminal, `DATABASE_URL` is exported and points at its database. Running `cargo run -p migrate` directly then targets the wrong cluster; sqlx aborts before applying anything, but the error is confusing. Always go through `mise run`, which supplies its own.

**The Xcode project is generated.** `ios/Ond.xcodeproj` is gitignored and rebuilt from `ios/project.yml`. Changing build settings in Xcode's UI works until the next `mise run ios:gen` throws it away — make the change in `project.yml` instead.

**Device builds need signing; the simulator doesn't.** `project.yml` reads `DEVELOPMENT_TEAM` from `${OND_DEV_TEAM}`, which XcodeGen substitutes at generate time. Unset, the reference is written through and Xcode resolves it as an undefined setting — no team, which is exactly what a simulator build wants and why a fresh clone needs no Apple ID. A device or archive build does need it; see the release section below.

**Regenerated Swift is committed.** After editing a `.proto`, `mise run generate:proto` rewrites files under `ios/Packages/OndCore/Sources/OndAPI/Generated/`. Commit them; the Xcode build does not run `buf`.

**Postgres 18 moved its data directory.** The compose volume mounts `/var/lib/postgresql`, not `/var/lib/postgresql/data`. Copying a volume line from an older project makes the container refuse to start with a long, easily-misread explanation.

**A StoreKit purchase in the simulator does not reach the server.** Buying Coach against the local `.storekit` configuration convinces the _client_ — `SubscriptionStore` unlocks the Coach tab and every gate reads it from StoreKit — but the transaction it produces is signed locally, so `SubmitAppStoreTransaction` rejects it (`x5c` carries 1 certificate, not Apple's chain) and the server still resolves you to `FREE`. `AssistantService` reads the tier from the row, never from the request, so the coach answers with its fixed fallback and the assistant looks broken when it is doing exactly what it says. `mise run dev:coach` writes what a real purchase would have. Watch for `entitlement sync deferred` in the log — that is this, not a network problem.
