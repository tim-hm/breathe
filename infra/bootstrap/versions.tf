# Applied once, by hand, before anything else exists — including the bucket the
# sibling root in `infra/` keeps its state in. That circularity is why this root
# keeps local state: there is nowhere remote to put it yet.
#
# Losing this state file is not an incident. Everything here is a named,
# long-lived singleton (one bucket, one user), so recovery is `tofu import`
# twice, and `prevent_destroy` on the bucket means a stray apply cannot take the
# real state down with it.

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
