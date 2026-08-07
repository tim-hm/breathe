# Provisioned with OpenTofu (`mise run infra:plan` / `infra:apply`), composed
# from the community terraform-aws-modules rather than hand-rolled resources.

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The bucket is created by infra/bootstrap, which must be applied first.
  # Written out in full rather than as a partial backend: `tofu init` with no
  # flags must reach the right state, because the alternative is an operator who
  # forgets `-backend-config` and silently starts a second, empty state.
  #
  # `use_lockfile` is OpenTofu's S3-native locking. The DynamoDB table the old
  # Terraform docs call for is not needed and is not created.
  #
  # `bucket` must match `state_bucket` in infra/bootstrap/variables.tf verbatim;
  # nothing reconciles the two literals. Renaming it is a state migration, not
  # an edit to this string — the procedure is in docs/deployment.md.
  backend "s3" {
    bucket       = "ond-tfstate-136339248297"
    key          = "ond/infra/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}
