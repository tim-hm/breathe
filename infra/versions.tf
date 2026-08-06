# Provisioned with OpenTofu (`mise run infra:plan` / `infra:apply`), composed
# from the community terraform-aws-modules rather than hand-rolled resources.
#
# State is local and gitignored — acceptable while one person applies from one
# machine. The day a second applier appears, move it to an S3 backend (OpenTofu
# supports S3-native locking; no DynamoDB table needed) before they run plan.

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
