output "repository_urls" {
  description = "Repository name -> repository URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Repository name -> repository ARN."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
