variable "region" {
  description = "AWS region. Matches infra/variables.tf — the state bucket lives beside what it describes."
  type        = string
  default     = "eu-west-2"
}

variable "state_bucket" {
  description = "Name of the OpenTofu state bucket. S3 names are globally unique, hence the account-number suffix. Must match the `bucket` in infra/versions.tf verbatim."
  type        = string
  default     = "breathe-tfstate-136339248297"
}

variable "tofu_user_name" {
  description = "IAM user the operator applies as, so day-to-day work stops using the account root. Its access key is created out of band (see docs/deployment.md) and never enters this state."
  type        = string
  default     = "breathe-tofu"
}
