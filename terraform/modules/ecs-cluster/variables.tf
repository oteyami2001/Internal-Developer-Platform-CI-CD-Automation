# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 4)
#
# Planned resources:
#   aws_ecs_cluster (Container Insights configurable; off in dev for cost)
#   aws_ecs_cluster_capacity_providers (FARGATE; FARGATE_SPOT optional for non-prod)

variable "name_prefix" {
  type = string
}

variable "container_insights" {
  type    = string
  default = "disabled"
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

variable "tags" {
  type    = map(string)
  default = {}
}
