output "elastic_ip" {
  description = "Point the A record for the hostname in infra/box/Caddyfile here. `mise run deploy` reads this to find the box."
  value       = aws_eip.api.public_ip
}

output "backup_bucket" {
  description = "Where the nightly pg_dump lands."
  value       = module.backups.s3_bucket_id
}
