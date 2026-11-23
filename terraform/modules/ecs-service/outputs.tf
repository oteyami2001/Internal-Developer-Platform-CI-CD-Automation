output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "task_definition_family" {
  description = "Task definition family (app-deploy registers new revisions here)."
  value       = aws_ecs_task_definition.this.family
}

output "task_security_group_id" {
  description = "Security group of the tasks."
  value       = aws_security_group.task.id
}

output "log_group_name" {
  description = "CloudWatch log group of the service."
  value       = aws_cloudwatch_log_group.this.name
}

output "execution_role_arn" {
  description = "Task execution role."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Task (application) role."
  value       = aws_iam_role.task.arn
}
