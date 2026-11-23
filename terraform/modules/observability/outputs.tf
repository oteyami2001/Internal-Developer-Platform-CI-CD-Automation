output "sns_topic_arn" {
  description = "Alert topic (confirm the e-mail subscription)."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "deployment_events_log_group" {
  description = "Log group with the history of ECS deployment events."
  value       = aws_cloudwatch_log_group.deployment_events.name
}

output "alarm_names" {
  description = "All alarm names."
  value = concat(
    [aws_cloudwatch_metric_alarm.alb_5xx.alarm_name, aws_cloudwatch_metric_alarm.target_5xx.alarm_name, aws_cloudwatch_metric_alarm.latency_p95.alarm_name, aws_cloudwatch_metric_alarm.unhealthy_targets.alarm_name],
    aws_cloudwatch_metric_alarm.no_healthy_targets[*].alarm_name,
    aws_cloudwatch_metric_alarm.service_cpu[*].alarm_name,
    aws_cloudwatch_metric_alarm.service_memory[*].alarm_name,
  )
}
