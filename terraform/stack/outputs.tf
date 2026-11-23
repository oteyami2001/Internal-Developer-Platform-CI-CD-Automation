output "name_prefix" {
  description = "Prefix for every resource name in this environment."
  value       = local.name_prefix
}

output "account_id" {
  description = "Verified AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "Verified AWS Region."
  value       = data.aws_region.current.region
}

output "tags" {
  description = "Platform tags applied to every resource."
  value       = local.tags
}
