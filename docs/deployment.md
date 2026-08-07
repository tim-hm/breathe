# Deployment

One Graviton EC2 instance running the API, Postgres, and Caddy under Docker Compose, provisioned by OpenTofu from `infra/`, deployed by `mise run deploy`. Nothing in this document runs automatically: provisioning and deploying are deliberate operator actions, and none of the `check`/CI machinery touches AWS.

## Shape

```text
infra/            OpenTofu root module — the AWS resources
infra/bootstrap/  applied once, before everything — the state bucket and the IAM user
infra/box/        what runs on the instance — compose.yaml + Caddyfile, rsynced by deploy
infra/cloud-init.yaml   first-boot setup — Docker, the data volume, the backup cron
Dockerfile        one image, both workspace binaries (api + migrate)
web/              the marketing one-pager, rsynced beside infra/box and served by Caddy
```

The public hostname is **`cadence.holmie.xyz`**, named in `infra/box/Caddyfile`. `holmie.xyz` is registered at **Porkbun** and served by Porkbun's nameservers, so its records are edited there — nothing in `infra/` manages DNS, and the `elastic_ip` output is what the A record points at.

The instance is disposable; the things worth keeping live elsewhere:

- **Postgres data** — on a separate EBS volume (`breathe-data` label, mounted at `/srv/data`), so replacing the instance replaces no data. The database password lives on that volume too (`/srv/data/breathe.env`), because Postgres keeps its own hash inside the cluster files — a fresh instance regenerating it would strand the data.
- **Backups** — nightly `pg_dump | gzip | aws s3 cp` from a cron installed by cloud-init, into the `backup_bucket` output, 30-day expiry. Credentials come from the instance profile; no keys exist on the box.
- **TLS certificates** — in the `caddy-data` Docker volume, persisted so redeploys never touch ACME rate limits.

The public entrance is Caddy on 443 (80 redirects and answers ACME challenges), reverse-proxying to the API on 18100. gRPC-Web is plain HTTP POST underneath, so no special proxy handling is needed. Postgres is not reachable from outside the compose network at all.

## The site

`web/` is two static files — `index.html` and `style.css`, no build step and no bundler. `mise run deploy` rsyncs the directory to `/srv/breathe/web/`, which `infra/box/compose.yaml` mounts read-only into Caddy.

`infra/box/Caddyfile` splits the hostname by path rather than running a second one, so there is one A record and one certificate. The API side is enumerated (`/breathe.v1.*`, `/health`, `/about`) and the site is the fallback, never the other way round: matching the proto package prefix covers every service the contract will ever grow, so a static file can never shadow an RPC.

The one-pager's technique glyphs are the reference for the apps' own drawings, with nothing checking the two agree — see [code-structure.md](code-structure.md) before editing them.

## Environment

The container gets exactly the three variables `crates/api/src/config.rs` reads, and no more — anything else belongs in config.rs as a derivation, per CLAUDE.md §1.4.

| Variable             | Required | Where it comes from                                                              |
| :------------------- | :------- | :------------------------------------------------------------------------------- |
| `BREATHE_ENV`        | yes      | Literal `production` in `infra/box/compose.yaml` — JSON logs, no permissive CORS |
| `DATABASE_URL`       | yes      | Assembled in the same file from the generated `POSTGRES_PASSWORD`                |
| `OPENROUTER_API_KEY` | no       | `/srv/data/breathe.env`, added by hand — see below                               |

`OPENROUTER_API_KEY` is the assistant's provider key, and the only optional one. Absent, the API boots normally and the assistant answers from its rule-based fallback; every RPC still returns a real answer, flagged so the client can say so. Add it the same way the password lives — appended to `/srv/data/breathe.env` on the data volume, which `/srv/breathe/.env` symlinks onto, so it survives replacing the instance:

```sh
ssh ubuntu@<elastic_ip> 'printf "OPENROUTER_API_KEY=%s\n" "<key>" | sudo tee -a /srv/data/breathe.env >/dev/null'
ssh ubuntu@<elastic_ip> 'cd /srv/breathe && docker compose up -d api'
```

The key never leaves the box: the model is called server-side precisely so no build of the app ever carries one. Rotating it is the same two commands with the old line removed first.

## Identity and state

Two AWS profiles, and the split is the point:

| Profile   | Who                         | May run                                           |
| :-------- | :-------------------------- | :------------------------------------------------ |
| `holmie`  | the account root            | `infra:bootstrap:*`, once, and nothing else       |
| `breathe` | the `breathe-tofu` IAM user | everything: `infra:plan`, `infra:apply`, `deploy` |

The mise tasks pin `AWS_PROFILE` themselves, so neither is something to remember or export.

State lives in the S3 bucket `infra/bootstrap` creates — versioned, encrypted, private, TLS-only, and `prevent_destroy`. Locking is OpenTofu's S3-native `use_lockfile`; the DynamoDB table older Terraform documentation calls for does not exist and is not needed.

`infra/bootstrap` keeps **local** state, because it builds the bucket the other root stores state in. Losing that file is not an incident: it manages one bucket and one IAM user, both named, both re-importable in two commands.

## Bootstrap (once per AWS account)

1. `mise run infra:bootstrap:init`, then `mise run infra:bootstrap:apply` — creates the state bucket and the `breathe-tofu` IAM user. This is the only step that runs as the account root.
2. Mint the user's credential. Tofu deliberately does not, because the provider would write the secret into a state file in plaintext:

   ```sh
   aws iam create-access-key --user-name breathe-tofu --profile holmie
   ```

3. Put it in `~/.aws/credentials` under `[breathe]`, with a matching `[profile breathe]` (`region = eu-west-2`) in `~/.aws/config`.
4. Delete the **root** access key in the IAM console. Root keys cannot be scoped, and an audit cannot tell one use of them from another — replacing them is the entire reason step 1 exists.

## First launch (deliberate, in order)

1. Bootstrap, above.
2. Create `infra/terraform.tfvars` (gitignored) with both required variables: `ssh_public_key`, and `admin_cidr` as `<your-ip>/32` for a stable address or the range your ISP hands out. Neither has a default — `tofu plan` prompts for a missing one and fails outright under `-input=false` — and `infra/variables.tf` says why a default for `admin_cidr` would be the wrong thing to commit. Being stranded outside your own CIDR by a DHCP renewal is not the failure it sounds like: the instance carries an SSM role, so Session Manager reaches it without 22/tcp.
3. `mise run infra:init` — downloads providers and modules, and reaches the S3 backend.
4. `mise run infra:plan` — read the plan — then `mise run infra:apply`.
5. At Porkbun, point `cadence.holmie.xyz` at the `elastic_ip` output with an `A` record. Do this before the first deploy: Caddy requests its certificate on first boot, and issuance fails (then retries with backoff) until the name resolves.
6. `mise run deploy` — builds the arm64 image locally, ships it over SSH (`docker save | docker load`, no registry), rsyncs `infra/box/`, runs `migrate` as a one-shot container, brings the stack up.
7. `curl https://cadence.holmie.xyz/health` → `{"status":"ok"}`, and `/about` for the commit now serving.

Every subsequent release is step 6 alone.

## Restore

```sh
aws s3 cp s3://<backup_bucket>/breathe-<date>.sql.gz - | gunzip |
  ssh ubuntu@<elastic_ip> 'docker compose -f /srv/breathe/compose.yaml exec -T db psql -U postgres breathe'
```

Restores into the live database; for a from-scratch rebuild, apply migrations first (`deploy` does) and restore over the empty schema.

## Decisions and their edges

- **Postgres in Docker, not RDS.** At V1 scale RDS buys nothing a dump schedule doesn't, and costs more than the instance itself. The graduation path is a `DATABASE_URL` change and one restore — take it when backups stop being an acceptable recovery story, not before.
- **No registry.** `docker save | ssh docker load` is the whole supply chain while there is one box. A registry earns its place when there are two, or when CI deploys.
- **S3 state, no DynamoDB.** OpenTofu locks against S3 itself (`use_lockfile`), so the lock table every Terraform tutorial provisions is dead weight. `infra/bootstrap` keeps local state only because it creates the bucket.
- **An IAM user, not SSO, and not least privilege.** One account and one operator do not justify standing up Identity Center. `AdministratorAccess` because this user's only job is applying a module that creates IAM roles, buckets, EC2 and EBS — scoping it would mean enumerating every service the module might ever grow into, and the enumeration would be stale immediately. The security this buys is not a smaller blast radius; it is a credential that can be rotated and revoked, which a root key cannot.
- **Provenance via build arg.** `.dockerignore` excludes `.git`, so `build.rs` cannot read the commit inside a container. `deploy` passes it as `GIT_COMMIT_HASH`, and `build.rs` prefers that over git — otherwise `/about` reports `"unknown"` in the one environment where the question matters.
- **The box self-heals but is not monitored.** `restart: unless-stopped` covers crashes; nothing yet pages anyone. M10's launch-readiness milestone owns real monitoring.
