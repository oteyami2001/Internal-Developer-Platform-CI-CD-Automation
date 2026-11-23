# Alerts, alarms, deployment-event history and a dashboard for one environment.
#   - SNS topic with an e-mail subscription (confirm the e-mail AWS sends).
#   - ALB alarms always exist; service alarms (healthy hosts, CPU, memory) only once a service runs.
#   - ECS deployment/service events -> SNS and a log group: a durable record of every deployment,
#     rollback and circuit-breaker action (required scenario 11).

variable "name_prefix" {
  description = "Resource name prefix, e.g. idp-dev."
  type        = string
}

variable "alert_email" {
  description = "Alert recipient (personal data: sensitive)."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "ECS cluster name (CloudWatch dimension)."
  type        = string
}

variable "service_name" {
  description = "ECS service name, or null while no service is deployed."
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch dimension)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch dimension)."
  type        = string
}

variable "alarm_thresholds" {
  description = "Alarm thresholds."
  type = object({
    http_5xx_per_5min = optional(number, 5)
    p95_latency_ms    = optional(number, 1000)
    cpu_percent       = optional(number, 80)
    memory_percent    = optional(number, 80)
  })
  default = {}
}

variable "log_retention_days" {
  description = "Retention of the deployment-events log group."
  type        = number
}
