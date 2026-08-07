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
  # The bucket keeps the name it was bootstrapped under. Renaming it would mean
  # creating a second bucket and migrating state into it, to change a string
  # only an operator ever reads — and the bucket carries `prevent_destroy`
  # precisely because state is the one thing here that is not reproducible. The
  # key does change: this deployment is provisioned from scratch under the new
  # name, and a fresh key is what makes that a clean slate rather than an edit.
  backend "s3" {
    bucket       = "breathe-tfstate-136339248297"
    key          = "ond/infra/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}
