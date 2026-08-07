# The two things that must exist before `infra/` can be applied at all: somewhere
# to keep state, and someone other than the account root to apply as.

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket

  # State is the only record of what exists in the account. Deleting it does not
  # delete the infrastructure — it strands it, unmanageable, until every resource
  # is imported by hand.
  lifecycle {
    prevent_destroy = true
  }
}

# OpenTofu writes state on every apply, so a corrupt or truncated write is the
# realistic failure, not deletion. Versions are what a rollback reads.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State contains every secret Tofu has ever seen. Refusing plaintext transport is
# cheap insurance that costs nothing to keep.
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  # A bucket policy that denies everything unconditionally would lock the account
  # out of its own state; the public access block must be in place first so the
  # policy is evaluated against a bucket that is already private.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# AdministratorAccess rather than a scoped policy: this user's whole job is to
# apply `infra/`, which creates IAM roles, S3 buckets, EC2 and EBS. Scoping it
# would mean enumerating every service the module might ever touch, and the
# enumeration would be wrong the first time the module grew. The security gain
# here is not least privilege — it is that the credential can be rotated and
# revoked at all, which a root access key cannot.
resource "aws_iam_user" "tofu" {
  name = var.tofu_user_name
}

resource "aws_iam_user_policy_attachment" "tofu_admin" {
  user       = aws_iam_user.tofu.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# No `aws_iam_access_key` here, deliberately: the provider would write the secret
# into this state file in plaintext, which is exactly what the bucket policy
# above exists to protect. `aws iam create-access-key` returns it once, to the
# operator, and it lives in ~/.aws/credentials. See docs/deployment.md.

output "state_bucket" {
  description = "Set as `bucket` in the backend block of infra/versions.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "tofu_user" {
  description = "Run `aws iam create-access-key --user-name <this>` to mint the credential for the `breathe` profile."
  value       = aws_iam_user.tofu.name
}
