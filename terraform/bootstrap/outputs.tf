output "account_id" {
  description = "Verified AWS account ID (caller identity matched aws_account_id)."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "Verified AWS Region."
  value       = data.aws_region.current.region
}

output "state_bucket" {
  description = "Terraform state bucket (backend.hcl `bucket`)."
  value       = aws_s3_bucket.state.id
}

output "github_role_arns" {
  description = "Role key -> ARN. Configure these on the matching GitHub environments (scripts/configure_github_environments.sh)."
  value       = module.github_roles.role_arns
}

output "github_trusted_subjects" {
  description = "Role key -> the exact OIDC subject it trusts."
  value       = module.github_roles.trusted_subjects
}

output "permissions_boundary_arns" {
  description = "Environment -> workload permissions boundary ARN."
  value       = { for e, m in module.boundary : e => m.boundary_arn }
}

output "ecr_repository_urls" {
  description = "Repository name -> URL."
  value       = module.ecr.repository_urls
}

output "cloudtrail_trail_arn" {
  description = "Management-events trail."
  value       = aws_cloudtrail.management.arn
}

output "cloudtrail_bucket" {
  description = "Bucket holding CloudTrail log files."
  value       = aws_s3_bucket.trail.id
}
