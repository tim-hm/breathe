output "elastic_ip" {
  description = "The box's public address. `mise run deploy` reads this to find it; the A record pointing at it is managed here rather than by hand."
  value       = aws_eip.api.public_ip
}

output "name_servers" {
  description = "Delegate the domain to these four at the registrar. The only DNS step that stays manual, and it is done once — every record after it is applied from infra/."
  value       = aws_route53_zone.primary.name_servers
}

output "backup_bucket" {
  description = "Where the nightly pg_dump lands."
  value       = module.backups.s3_bucket_id
}
