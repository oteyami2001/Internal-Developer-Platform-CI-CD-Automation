# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 4/7)
#
# Planned resources:
#   aws_sns_topic (+ e-mail subscription, SSE with the AWS-managed key)
#   aws_cloudwatch_metric_alarm: ALB 5xx, target 5xx, UnHealthyHostCount, p95 TargetResponseTime,
#                                ECS RunningTaskCount < desired, CPU/memory utilisation
#   aws_cloudwatch_dashboard (one per environment: ALB, ECS, deployment events)
#   aws_cloudwatch_event_rule: ECS deployment state changes (COMPLETED / FAILED / ROLLBACK) -> SNS + log group

variable "name_prefix" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "services" {
  description = "Service name -> ALB target group ARN suffix."
  type        = map(string)
}

variable "alb_arn_suffix" {
  type = string
}

variable "alarm_thresholds" {
  type = object({
    http_5xx_per_5min = optional(number, 5)
    p95_latency_ms    = optional(number, 1000)
  })
  default = {}
}

variable "log_retention_days" {
  type = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
