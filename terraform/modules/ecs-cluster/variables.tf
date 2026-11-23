# ECS cluster (Fargate only). Container Insights is off in dev for cost; enable it for prod.

variable "name_prefix" {
  description = "Cluster name, e.g. idp-dev (the deploy role is scoped to cluster/<name_prefix>)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase characters."
  }
}

variable "container_insights" {
  description = "disabled | enabled | enhanced (CloudWatch charges per metric)."
  type        = string
  default     = "disabled"
  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be disabled, enabled or enhanced."
  }
}

variable "use_fargate_spot" {
  description = "Non-prod cost option. Spot tasks can be interrupted with a 2-minute warning."
  type        = bool
  default     = false
}
