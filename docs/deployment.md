# Deployment

One Graviton EC2 instance running the API, Postgres, and Caddy under Docker Compose, provisioned by OpenTofu from `infra/`, deployed by `mise run deploy`. Nothing in this document runs automatically: provisioning and deploying are deliberate operator actions, and none of the `check`/CI machinery touches AWS.

## Shape

```text
infra/            OpenTofu root module — the AWS resources
infra/box/        what runs on the instance — compose.yaml + Caddyfile, rsynced by deploy
infra/cloud-init.yaml   first-boot setup — Docker, the data volume, the backup cron
Dockerfile        one image, both workspace binaries (api + migrate)
```

The instance is disposable; the things worth keeping live elsewhere:

- **Postgres data** — on a separate EBS volume (`breathe-data` label, mounted at `/srv/data`), so replacing the instance replaces no data. The database password lives on that volume too (`/srv/data/breathe.env`), because Postgres keeps its own hash inside the cluster files — a fresh instance regenerating it would strand the data.
- **Backups** — nightly `pg_dump | gzip | aws s3 cp` from a cron installed by cloud-init, into the `backup_bucket` output, 30-day expiry. Credentials come from the instance profile; no keys exist on the box.
- **TLS certificates** — in the `caddy-data` Docker volume, persisted so redeploys never touch ACME rate limits.

The public entrance is Caddy on 443 (80 redirects and answers ACME challenges), reverse-proxying to the API on 18100. gRPC-Web is plain HTTP POST underneath, so no special proxy handling is needed. Postgres is not reachable from outside the compose network at all.

## Environment

The container gets exactly the two variables `crates/api/src/config.rs` reads: `BREATHE_ENV=production` (JSON logs, no permissive CORS) and `DATABASE_URL` (assembled in `infra/box/compose.yaml` from the generated password). Anything more belongs in config.rs as a derivation, per CLAUDE.md §1.4.

## First launch (deliberate, in order)

1. `mise run infra:init` — downloads providers and modules; touches nothing.
2. Create `infra/terraform.tfvars` (gitignored) with `ssh_public_key`, and `admin_cidr` if your IP is stable.
3. AWS credentials in the shell (`AWS_PROFILE` or SSO), then `mise run infra:plan` — read the plan.
4. `mise run infra:apply`.
5. Point the A record for the hostname in `infra/box/Caddyfile` at the `elastic_ip` output. Do this before the first deploy: Caddy requests its certificate on first boot, and issuance fails (then retries with backoff) until the name resolves.
6. `mise run deploy` — builds the arm64 image locally, ships it over SSH (`docker save | docker load`, no registry), rsyncs `infra/box/`, runs `migrate` as a one-shot container, brings the stack up.
7. `curl https://<hostname>/health` → `{"status":"ok"}`.

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
- **Local OpenTofu state.** Acceptable while one person applies from one machine; `infra/versions.tf` records the move to S3-backed state (OpenTofu's native locking, no DynamoDB) the day that stops being true.
- **The box self-heals but is not monitored.** `restart: unless-stopped` covers crashes; nothing yet pages anyone. M10's launch-readiness milestone owns real monitoring.
