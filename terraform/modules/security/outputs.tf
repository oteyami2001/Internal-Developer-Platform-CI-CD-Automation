output "boundary_arn" {
  description = "ARN of the environment's workload permissions boundary."
  value       = aws_iam_policy.boundary.arn
}

output "boundary_name" {
  description = "Name of the boundary policy."
  value       = aws_iam_policy.boundary.name
}
