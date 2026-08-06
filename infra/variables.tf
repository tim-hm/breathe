variable "region" {
  description = "AWS region. London by default — closest EU-adjacent region to the operator."
  type        = string
  default     = "eu-west-2"
}

variable "instance_type" {
  description = "Graviton (arm64) instance — the Dockerfile builds linux/arm64. t4g.small's 2 GiB is the smallest that leaves Postgres real headroom next to the API and Caddy; micro's 1 GiB does not. Bump here if it stops being enough."
  type        = string
  default     = "t4g.small"
}

variable "ssh_public_key" {
  description = "The operator's SSH public key (the `ssh-ed25519 ...` line). Required — there is no sensible default for who may log in."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH. Defaults open because a home IP changes under DHCP; tighten to <your-ip>/32 in terraform.tfvars if yours is stable."
  type        = string
  default     = "0.0.0.0/0"
}

variable "data_volume_gb" {
  description = "Size of the EBS volume holding Postgres data. Separate from the root volume so the instance stays disposable: replace the box, reattach the data."
  type        = number
  default     = 10
}
