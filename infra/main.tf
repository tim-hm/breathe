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

  name        = "breathe-api"
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

  bucket_prefix = "breathe-backups-"

  # Dumps are worthless past the point anyone would restore them; 30 days keeps
  # the bucket from quietly accumulating forever.
  lifecycle_rule = [
    {
      id      = "expire-dumps"
      enabled = true
      expiration = {
        days = 30
      }
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

resource "aws_iam_role" "api" {
  name               = "breathe-api"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy" "write_backups" {
  name   = "write-backups"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.write_backups.json
}

resource "aws_iam_instance_profile" "api" {
  name = "breathe-api"
  role = aws_iam_role.api.name
}

resource "aws_key_pair" "admin" {
  key_name   = "breathe-admin"
  public_key = var.ssh_public_key
}

module "instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name = "breathe-api"

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [module.security_group.security_group_id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.api.name

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    backup_bucket = module.backups.s3_bucket_id
    region        = var.region
  })

  # cloud-init formats and mounts the data volume by label on first boot; a
  # user_data change must not silently rebuild the box out from under it.
  user_data_replace_on_change = false
}

# Postgres data lives here, not on the root volume, so replacing the instance
# replaces nothing that matters.
resource "aws_ebs_volume" "data" {
  availability_zone = module.instance.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"

  tags = {
    Name = "breathe-data"
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
