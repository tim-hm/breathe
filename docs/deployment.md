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

The public hostname is **`ondbreathe.app`**, named twice on purpose: as the Route53 zone in `infra/main.tf` and as the site block in `infra/box/Caddyfile`. Nothing renders the Caddyfile — deploy rsyncs it as-is — so those two literals are kept in step by hand, and both files say so.

DNS is applied from `infra/`, not edited at the registrar: the hosted zone and the apex `A` record land with the address they point at, so a record aimed at a released IP is not a state this repo can reach. The registrar holds one thing, the NS delegation, set once from the `name_servers` output.

The zone also carries the domain's mail, which no part of this deployment serves — the box runs no mail server. Five values across four record sets hand it to Google Workspace, where the name is enrolled as a secondary domain of a Workspace registered under a different one — the two apex `TXT` strings share one set, which is why they cannot be separate resources:

| Record                         | What it does                                                                  |
| :----------------------------- | :---------------------------------------------------------------------------- |
| apex `TXT` `google-site-…`     | Proves control of the zone. Re-checked, so deleting it un-verifies the domain |
| apex `TXT` `v=spf1 …`          | Names Google as the only sender. At `~all`, so other senders are marked       |
| apex `MX` `1 smtp.google.com.` | Delivery. One host, not the five `ASPMX` records older guides give            |
| `google._domainkey` `TXT`      | DKIM public key, split across two strings — see the comment on the resource   |
| `_dmarc` `TXT` `p=none`        | Makes the two above enforceable. Reports only, and no `rua` yet               |

**Those five values belong to one Workspace tenant.** Applying `infra/` into a fresh AWS account publishes another tenant's verification token and DKIM key, which verifies nothing and signs nothing. A second deployment replaces all five from its own Workspace admin console, or drops them if it serves no mail.

The instance is disposable; the things worth keeping live elsewhere:

- **Postgres data** — on a separate EBS volume (`ond-data` label, mounted at `/srv/data`), so replacing the instance replaces no data. The database password lives on that volume too (`/srv/data/ond.env`), because Postgres keeps its own hash inside the cluster files — a fresh instance regenerating it would strand the data.
- **Backups** — nightly `pg_dump | gzip | aws s3 cp` from a cron installed by cloud-init, into the `backup_bucket` output, 30-day expiry. Credentials come from the instance profile; no keys exist on the box.
- **TLS certificates** — in the `caddy-data` Docker volume, persisted so redeploys never touch ACME rate limits.

The public entrance is Caddy on 443 (80 redirects and answers ACME challenges), reverse-proxying to the API on 18100. gRPC-Web is plain HTTP POST underneath, so no special proxy handling is needed. Postgres is not reachable from outside the compose network at all.

## The site

`web/` is four static files — `index.html`, `privacy.html`, `support.html`, and `style.css`, no build step and no bundler. `mise run deploy` rsyncs the directory to `/srv/ond/web/`, which `infra/box/compose.yaml` mounts read-only into Caddy. The two document pages are reached without their extension (`/privacy`, `/support`), which the `try_files` directive in the Caddyfile is what makes work — the app ships those URLs as literals.

`infra/box/Caddyfile` splits the hostname by path rather than running a second one, so there is one A record and one certificate. The API side is enumerated (`/ond.v1.*`, `/health`, `/about`) and the site is the fallback, never the other way round: matching the proto package prefix covers every service the contract will ever grow, so a static file can never shadow an RPC.

The one-pager's technique glyphs are the reference for the apps' own drawings, with nothing checking the two agree — see [code-structure.md](code-structure.md) before editing them.

## Environment

The container gets exactly the two variables `crates/api/src/config.rs` reads, and no more — anything else belongs in config.rs as a derivation, per CLAUDE.md §1.4.

| Variable       | Required | Where it comes from                                                              |
| :------------- | :------- | :------------------------------------------------------------------------------- |
| `OND_ENV`      | yes      | Literal `production` in `infra/box/compose.yaml` — JSON logs, no permissive CORS |
| `DATABASE_URL` | yes      | Assembled in the same file from the generated `POSTGRES_PASSWORD`                |

**The assistant has no variable, and that is the design.** It calls Amazon Bedrock directly, signing each call with the `ond-api` instance profile that `infra/main.tf` attaches — reachable from inside the container because `http_put_response_hop_limit` is 2, the same reason the backup cron's `aws s3 cp` works. So there is no key on the box, nothing to add after a rebuild, and nothing to rotate. Where the box cannot sign for Bedrock at all — a laptop with no AWS identity, a CI runner — the API boots normally and the assistant answers from its rule-based fallback; every RPC still returns a real answer, flagged so the client can say so.

The two things that _are_ configuration live in code and in OpenTofu: which model, in `BEDROCK_MODEL_ID`; and which regions its inference profile may route to, in `assistant_profile_regions`. See [the assistant's permission](#the-assistants-permission) below.

## The assistant's permission

`aws_iam_role_policy.invoke_model` in `infra/main.tf` is what lets the box call the coach's model. It grants `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` — the streaming one is not optional, because the chat RPC streams — over two ARN families, and both are required:

- the **inference profile**, `arn:aws:bedrock:eu-west-2:<account>:inference-profile/eu.anthropic.…`, which is where the call is addressed; and
- the **underlying foundation model** in every region that profile may forward to, `arn:aws:bedrock:<destination>::foundation-model/anthropic.…`.

A policy granting only the first is the failure worth knowing about. It is valid, it plans, it applies — and then every call comes back `AccessDenied`, on the box, because an invocation is authorised against both. The foundation-model id is derived from the profile id rather than written twice, so those two cannot drift.

The destination list is `assistant_profile_regions`, and it has **no default on purpose**. It is read from the inference profile's detail page in the Bedrock console, and a guessed list fails only when Bedrock happens to route to the region that was left out — so a plan that stops for a missing value is where that mistake belongs. The same list is what `web/privacy.html` asserts about where coach requests are processed, which is the other reason not to infer it. It lives in `infra/terraform.tfvars` beside `ssh_public_key` and `admin_cidr`:

```hcl
assistant_profile_regions = ["eu-west-1", "eu-central-1", ...]  # from the console
```

Changing the model means changing `BEDROCK_MODEL_ID` in `crates/api/src/config.rs` and `assistant_inference_profile` here together, then re-reading the destination list — a different profile can have a different one. That constant's doc comment carries the standing constraint on which models may be adopted at all.

## Identity and state

Two AWS profiles, and the split is the point:

| Profile  | Who                     | May run                                           |
| :------- | :---------------------- | :------------------------------------------------ |
| `holmie` | the account root        | `infra:bootstrap:*`, once, and nothing else       |
| `ond`    | the `ond-tofu` IAM user | everything: `infra:plan`, `infra:apply`, `deploy` |

The mise tasks pin `AWS_PROFILE` themselves, so neither is something to remember or export.

State lives in the S3 bucket `infra/bootstrap` creates — versioned, encrypted, private, TLS-only, and `prevent_destroy`. Locking is OpenTofu's S3-native `use_lockfile`; the DynamoDB table older Terraform documentation calls for does not exist and is not needed.

The bucket is `ond-tfstate-136339248297` and the user is `ond-tofu` — both renamed from `breathe-*` after the app became önd, so nothing in the account still answers to the old name. The bucket name is written in two places that nothing reconciles: `state_bucket` in `infra/bootstrap/variables.tf`, which creates it, and the `backend "s3"` block in `infra/versions.tf`, which reads it.

Renaming it again is four steps, and the first is the one that is not obvious. `bucket` is ForceNew, so changing it plans a destroy-and-recreate — which `prevent_destroy` on that resource refuses outright, failing the whole plan before anything is created. The guard is right and stays; bootstrap has to be told to forget the old bucket instead of being asked to replace it:

```sh
# 1. Bootstrap forgets the old bucket. It stays alive, unmanaged, holding state.
tofu -chdir=infra/bootstrap state rm \
  aws_s3_bucket.tfstate aws_s3_bucket_policy.tfstate \
  aws_s3_bucket_public_access_block.tfstate \
  aws_s3_bucket_server_side_encryption_configuration.tfstate \
  aws_s3_bucket_versioning.tfstate
# 2. Create the new one, with the new name already in variables.tf.
mise run infra:bootstrap:apply
# 3. Carry state across, having edited the backend literal in infra/versions.tf.
AWS_PROFILE=ond tofu -chdir=infra init -migrate-state
# 4. Only once `mise run infra:plan` is a clean no-op: empty and delete the old
#    bucket by hand. It is versioned, so every version must go before the bucket.
```

Editing the backend literal on its own — without step 2 having created the bucket it names — points the backend at nothing and strands every resource.

`infra/bootstrap` keeps **local** state, because it builds the bucket the other root stores state in. Losing that file is not an incident: it manages one bucket and one IAM user, both named, both re-importable in two commands.

## Bootstrap (once per AWS account)

1. `mise run infra:bootstrap:init`, then `mise run infra:bootstrap:apply` — creates the state bucket and the `ond-tofu` IAM user. This is the only step that runs as the account root.
2. Mint the user's credential. Tofu deliberately does not, because the provider would write the secret into a state file in plaintext:

   ```sh
   aws iam create-access-key --user-name ond-tofu --profile holmie
   ```

3. Put it in `~/.aws/credentials` under `[ond]`, with a matching `[profile ond]` (`region = eu-west-2`) in `~/.aws/config`.
4. Delete the **root** access key in the IAM console. Root keys cannot be scoped, and an audit cannot tell one use of them from another — replacing them is the entire reason step 1 exists.

## First launch (deliberate, in order)

1. Bootstrap, above.
2. Create `infra/terraform.tfvars` (gitignored) with both required variables: `ssh_public_key`, and `admin_cidr` as `<your-ip>/32` for a stable address or the range your ISP hands out. Neither has a default — `tofu plan` prompts for a missing one and fails outright under `-input=false` — and `infra/variables.tf` says why a default for `admin_cidr` would be the wrong thing to commit. Being stranded outside your own CIDR by a DHCP renewal is not the failure it sounds like: the instance carries an SSM role, so Session Manager reaches it without 22/tcp.
3. `mise run infra:init` — downloads providers and modules, and reaches the S3 backend.
4. `mise run infra:plan` — read the plan — then `mise run infra:apply`.
5. Delegate the domain: set the four addresses from the `name_servers` output as `ondbreathe.app`'s nameservers at the registrar, then wait until `dig +short ondbreathe.app` answers with the `elastic_ip`. Do this before the first deploy — Caddy requests its certificate on first boot, and issuance fails (then retries with backoff) until the name resolves. The `A` record itself was applied in step 4; delegation is what makes the world able to read it.
6. `mise run deploy` — builds the arm64 image locally, ships it over SSH (`docker save | docker load`, no registry), rsyncs `infra/box/`, runs `migrate` as a one-shot container, brings the stack up.
7. `curl https://ondbreathe.app/health` → `{"status":"ok"}`, and `/about` for the commit now serving.

Every subsequent release is step 6 alone.

## Restore

```sh
aws s3 cp s3://<backup_bucket>/ond-<date>.sql.gz - | gunzip |
  ssh ubuntu@<elastic_ip> 'docker compose -f /srv/ond/compose.yaml exec -T db psql -U postgres ond'
```

Restores into the live database; for a from-scratch rebuild, apply migrations first (`deploy` does) and restore over the empty schema.

## Decisions and their edges

- **Postgres in Docker, not RDS.** At V1 scale RDS buys nothing a dump schedule doesn't, and costs more than the instance itself. The graduation path is a `DATABASE_URL` change and one restore — take it when backups stop being an acceptable recovery story, not before.
- **No registry.** `docker save | ssh docker load` is the whole supply chain while there is one box. A registry earns its place when there are two, or when CI deploys.
- **S3 state, no DynamoDB.** OpenTofu locks against S3 itself (`use_lockfile`), so the lock table every Terraform tutorial provisions is dead weight. `infra/bootstrap` keeps local state only because it creates the bucket.
- **An IAM user, not SSO, and not least privilege.** One account and one operator do not justify standing up Identity Center. `AdministratorAccess` because this user's only job is applying a module that creates IAM roles, buckets, EC2 and EBS — scoping it would mean enumerating every service the module might ever grow into, and the enumeration would be stale immediately. The security this buys is not a smaller blast radius; it is a credential that can be rotated and revoked, which a root key cannot.
- **Provenance via build arg.** `.dockerignore` excludes `.git`, so `build.rs` cannot read the commit inside a container. `deploy` passes it as `GIT_COMMIT_HASH`, and `build.rs` prefers that over git — otherwise `/about` reports `"unknown"` in the one environment where the question matters.
- **The box self-heals but is not monitored.** `restart: unless-stopped` covers crashes; nothing yet pages anyone. Real monitoring is tracked as launch work rather than built here.
