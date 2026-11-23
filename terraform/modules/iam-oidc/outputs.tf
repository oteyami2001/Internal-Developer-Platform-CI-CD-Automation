output "role_arns" {
  description = "Role key (<env>-plan, <env>-apply, <env>-deploy, image-push) -> role ARN."
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}

output "trusted_subjects" {
  description = "Role key -> the single OIDC subject it trusts."
  value       = { for k, r in local.roles : k => r.subject }
}
