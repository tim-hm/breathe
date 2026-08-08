# One box, deliberately: API + Postgres + Caddy under Docker Compose on a
# single Graviton instance, data on its own EBS volume, nightly dumps to S3.
# The instance is disposable — everything it runs arrives via `mise run deploy`
# (image over SSH, compose files via rsync), and everything worth keeping lives
# on the data volume or in the bucket. RDS is the graduation path, not the
# starting point: at V1 scale it buys nothing a dump schedule doesn't.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# The instance and its data volume must land in the same availability zone, and
# the subnet is what decides. Reading the AZ off the subnet rather than off the
# instance is load-bearing: it lets the volume be built before the instance, so
# the instance's cloud-init can name the volume it is waiting for. The other
# direction is a dependency cycle.
data "aws_subnet" "selected" {
  id = data.aws_subnets.default.ids[0]
}

data "aws_ami" "ubuntu" {
  most_recent = true
  # Canonical's AWS publisher account.
  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "ond-api"
  description = "HTTP(S) from everywhere, SSH from the admin CIDR"
  vpc_id      = data.aws_vpc.default.id

  ingress_with_cidr_blocks = [
    {
      rule        = "https-443-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      # Caddy answers 80 only to redirect to HTTPS and to solve ACME challenges.
      rule        = "http-80-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      rule        = "ssh-tcp"
      cidr_blocks = var.admin_cidr
    },
  ]

  egress_rules = ["all-all"]
}

module "backups" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket_prefix = "ond-backups-"

  # A nightly dump holds the whole `users` table, and under this identity model
  # every `users.id` *is* the bearer credential for that person's profile,
  # journey and entitlement — so this bucket takes the same hardening the state
  # bucket takes in bootstrap/main.tf, stated rather than inherited. The module's
  # v4 defaults already block public access and AWS encrypts new buckets by
  # default; writing both out is what stops an upstream default changing under a
  # major version bump from silently relaxing the more sensitive of the two
  # buckets. No `prevent_destroy` to match, though: dumps expire at 30 days by
  # design, so this bucket is reproducible in a way state never is.
  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
      bucket_key_enabled = true
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # The dump crosses the public internet from the box's `aws s3 cp`; refusing
  # plaintext transport is the same cheap insurance bootstrap takes on state.
  attach_deny_insecure_transport_policy = true

  # Dumps are worthless past the point anyone would restore them; 30 days keeps
  # the bucket from quietly accumulating forever. Both of the other two clauses
  # exist to keep that 30 honest:
  #
  # Versioning turns `expiration` into a delete marker rather than a delete, so
  # without a noncurrent rule the bytes would stay for ever and the number above
  # would be fiction. One day, not thirty — the current-version expiry *is* the
  # retention policy, and the noncurrent window only has to outlast a mistaken
  # delete.
  #
  # The cron pipes `pg_dump | gzip | aws s3 cp -` from stdin, which is always a
  # multipart upload, so a reboot or a dropped link mid-dump strands parts that
  # are billed as storage and are invisible to both expiry rules.
  lifecycle_rule = [
    {
      id      = "expire-dumps"
      enabled = true
      expiration = {
        days = 30
      }
      noncurrent_version_expiration = {
        days = 1
      }
      abort_incomplete_multipart_upload_days = 7
    }
  ]
}

# The instance may write backups and nothing else — no keys on the box, just
# the instance profile.
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "write_backups" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.backups.s3_bucket_arn}/*"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  # The foundation model behind the inference profile: the same id with the
  # geography prefix taken off, because that prefix is the profile and not part
  # of the model's name. Derived rather than written out a second time — two
  # literals naming one model is a pair that can disagree, and the way it would
  # disagree is an AccessDenied at invoke time.
  #
  # The optional group matches `eu.`, `us.`, `apac.` and anything else shaped
  # like a geography, and leaves a profile id carrying no prefix alone.
  assistant_foundation_model = regex("^(?:[a-z]{2,4}\\.)?(.*)$", var.assistant_inference_profile)[0]
}

# The assistant's model calls. Scoped to one profile and one model rather than
# `bedrock:*` on `*`, because this role is what an SSRF in anything the box runs
# would be reaching for.
#
# Both ARN families are load-bearing and the second one is the trap. Invoking a
# cross-region inference profile is authorised twice: once against the profile,
# which is where the call is addressed, and once against the underlying
# foundation model in whichever destination region Bedrock forwards it to. A
# policy naming only the profile is accepted by a plan, applies cleanly, and
# then fails every call with AccessDenied — in production, because that is the
# first place a real invocation happens.
#
# `var.assistant_profile_regions` therefore has to be the profile's *complete*
# destination list, not the regions we expect to be used: a region left out is a
# failure that appears only when Bedrock happens to route there under load.
data "aws_iam_policy_document" "invoke_model" {
  statement {
    actions = [
      "bedrock:InvokeModel",
      # Not optional: the chat RPC streams, so this is the action the coach
      # actually uses on the path a person watches.
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = concat(
      # System-defined inference profiles are account-scoped and live in the
      # region the call is signed for — the box's own.
      ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.assistant_inference_profile}"],
      # Foundation models are not account-scoped, hence the empty account field.
      [for destination in var.assistant_profile_regions :
        "arn:aws:bedrock:${destination}::foundation-model/${local.assistant_foundation_model}"
      ],
    )
  }
}

resource "aws_iam_role" "api" {
  name               = "ond-api"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy" "write_backups" {
  name   = "write-backups"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.write_backups.json
}

resource "aws_iam_role_policy" "invoke_model" {
  name   = "invoke-model"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.invoke_model.json
}

# Break-glass. SSH is the only other way in, and the situations worth planning
# for — a lost key, a security group edited into a corner, a box that boots but
# does not finish cloud-init — are exactly the ones where SSH is what broke.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "api" {
  name = "ond-api"
  role = aws_iam_role.api.name
}

resource "aws_key_pair" "admin" {
  key_name   = "ond-admin"
  public_key = var.ssh_public_key
}

module "instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name = "ond-api"

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [module.security_group.security_group_id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.api.name

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    backup_bucket = module.backups.s3_bucket_id
    region        = var.region
    # Nitro ignores the /dev/sdf attachment name and enumerates volumes as
    # unpredictable /dev/nvme*n1, but udev also names each one by its EBS volume
    # ID — with the dash stripped, because that is what the NVMe serial field
    # holds. Resolving the path here rather than probing for it on the box means
    # first boot looks for one exact device instead of guessing.
    data_device = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
  })

  # cloud-init formats and mounts the data volume by label on first boot; a
  # user_data change must not silently rebuild the box out from under it.
  user_data_replace_on_change = false

  # The module's volume_tags apply to every volume attached to the instance,
  # including the data volume, which is a separate resource carrying its own
  # Name. Left on, the two rewrite that tag past each other and every plan shows
  # a change that no apply ever settles — which is how operators learn to skim
  # plans instead of reading them.
  enable_volume_tags = false

  # IMDSv2 only — an unauthenticated metadata endpoint is reachable from any
  # SSRF in anything the box runs, and it hands out the instance profile's
  # credentials. hop_limit 2 rather than the default 1 because the containers sit
  # one network hop away behind Docker's bridge, and the backup cron's
  # `aws s3 cp` reads its credentials from exactly this endpoint.
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # The AMI's own default is 8 GiB and unencrypted. 8 GiB does not survive
  # `docker save | docker load` cycles accumulating images alongside the build
  # cache. Both attributes are ForceNew, so they are cheap now and cost an
  # instance replacement later.
  root_block_device = {
    size      = 20
    type      = "gp3"
    encrypted = true
  }
}

# Postgres data lives here, not on the root volume, so replacing the instance
# replaces nothing that matters.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  # Every row the product has, at rest. ForceNew, so turning it on later means
  # snapshot, restore, reattach — not an edit.
  encrypted = true

  tags = {
    Name = "ond-data"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = module.instance.id
}

# A stable address to hang the DNS A record on: the instance can be rebuilt
# without touching DNS.
resource "aws_eip" "api" {
  instance = module.instance.id
  domain   = "vpc"
}

# DNS. The zone lives here rather than at the registrar so the record and the
# address it points at are applied together — that pairing was the one manual
# step in a launch, and a record left pointing at a released address is a
# failure nothing in this repo could have caught. The registrar keeps only the
# NS delegation, which is set once and never again.
#
# The name must also match the site block in infra/box/Caddyfile. Caddy's
# config is rsynced as a static file rather than rendered, so neither side can
# derive the other; they are two literals that have to agree, and the Caddyfile
# says so too.
resource "aws_route53_zone" "primary" {
  name = "ondbreathe.app"
}

resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = aws_route53_zone.primary.name
  type    = "A"
  # Short, because the value worth changing quickly is exactly this one: an
  # elastic IP means the record is stable in normal operation, so the only time
  # it moves is the time somebody is waiting on it.
  ttl     = 300
  records = [aws_eip.api.public_ip]
}

# Mail for the domain, and the four records that authenticate it. Every value
# here belongs to one Google Workspace tenant — see docs/deployment.md before
# applying this into a fresh account.

# The apex TXT set. DNS keeps one TXT set per name, so every apex string lives in
# the list below: a second `aws_route53_record` at this name does not add to this
# one, it fights it. Only one string may start `v=spf1` — two SPF policies is a
# `permerror`, which receivers treat as no policy at all.
#
# Google re-checks the verification token rather than reading it once, so
# deleting it after enrolment un-verifies the domain.
resource "aws_route53_record" "apex_txt" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = aws_route53_zone.primary.name
  type    = "TXT"
  ttl     = 3600
  records = [
    "google-site-verification=ytC4-ZAJ7dO3fLsV52iJmQDu8h27cLFsmFcLHrwgCdg",
    # `~all` rather than `-all`: forwarding breaks SPF by design, because a
    # forwarder relays under its own address. A hard fail rejects that mail.
    "v=spf1 include:_spf.google.com ~all",
  ]
}

# One host at priority 1, not the five ASPMX records older guides still give:
# Google replaced that set, and running both generations of it delivers to two
# places at once.
resource "aws_route53_record" "apex_mx" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = aws_route53_zone.primary.name
  type    = "MX"
  ttl     = 3600
  records = ["1 smtp.google.com."]
}

# The public half of the key Google signs outgoing mail with, under the selector
# named in a signature's `s=` tag.
#
# One key split across two strings: a DNS character-string caps at 255 bytes and
# this key's base64 runs to 408, so the `""` in the middle is a real boundary,
# not a typo. A resolver concatenates adjacent strings before any verifier parses
# them.
resource "aws_route53_record" "google_domainkey" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "google._domainkey.${aws_route53_zone.primary.name}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsn5him2Gh5VlT5TgFPytX39+sK9LWweR0ptYpKwkWELZrDJBGVil2ChdVKciIva5HkRUghEdqnBjEl4fSh5qZZYmePE6MvM+AWQ2KrUSU0reHvWXjZZZUzfkHzp7doUc8rw/AKfizCU4KOdVujNqHrp7rAdbxJCu2FKeSO0OMfIFUrLnhC7d1X3mnDRyeXDdq26\"\"LzDtUoArd3SLRvBEcrCq49xvJ2SnnmAodt4cKFqVUxthxe97Hi1k4rCfS3ERhCOhw06Vqtgc/F040rTQ1lBCYZ08AnmnG1lNOi4IQwfNgUfn+t0UGJz4D0weQaLYSaL/4kd/AqsgyX5rHpqj/nQIDAQAB"]
}

# What makes the two records above enforceable: without a policy, a receiver
# holding a failing signature has nothing telling it what to do.
#
# This record does not enforce anything yet, and does not collect anything
# either. `p=none` asks receivers to act on nothing, and with no `rua` there is
# nowhere for them to report to — so today it is a placeholder that reserves the
# name, not a control. That is deliberate on both halves: a policy written before
# anyone has watched a week of traffic rejects the sender somebody forgot about,
# and there is no mailbox in this domain yet to read reports at. An address in
# another domain only receives them if that zone publishes
# `ondbreathe.app._report._dmarc.<their-domain>`, which is why `rua` is not
# simply pointed elsewhere.
#
# Turning it into a control is two edits in order: add `rua` and read the reports
# first, then tighten `p`.
resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "_dmarc.${aws_route53_zone.primary.name}"
  type    = "TXT"
  # Short, for the reason the apex A record is short: this is the one record here
  # written to be changed, and tightening a DMARC policy wrong loses mail
  # silently. At 3600 the bad version stands for an hour at every receiver that
  # cached it, and the rollback is stale for another hour.
  ttl     = 300
  records = ["v=DMARC1; p=none"]
}
