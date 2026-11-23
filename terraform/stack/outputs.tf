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

output "service_url" {
  description = "Base URL of the service (reachable only from the allowed /32 in demo mode)."
  value       = module.load_balancer.url
}

output "service_deployed" {
  description = "Whether an ECS service is running (false until Phase 5 publishes an image)."
  value       = local.deploy_service
}

output "ecs_cluster_name" {
  description = "ECS cluster."
  value       = module.ecs_cluster.cluster_name
}

output "service_log_group" {
  description = "Application log group (null until the service exists)."
  value       = local.deploy_service ? module.service[0].log_group_name : null
}

output "dashboard_name" {
  description = "CloudWatch dashboard."
  value       = module.observability.dashboard_name
}

output "alert_topic_arn" {
  description = "SNS topic for alarms and deployment events."
  value       = module.observability.sns_topic_arn
}

output "deployment_events_log_group" {
  description = "History of ECS deployment events."
  value       = module.observability.deployment_events_log_group
}
