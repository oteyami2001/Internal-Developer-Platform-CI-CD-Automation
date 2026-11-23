# One ECS Fargate service from a validated service manifest.
#
# Hard-coded by design (no variable can turn them off): non-root user 10001, read-only root
# filesystem, no privileged mode, no Linux capability additions, FARGATE launch type, awslogs.
#
# Release ownership: Terraform creates the service and its first task definition. Later releases
# are new task-definition revisions registered by app-deploy.yml (Phase 5), so the service ignores
# task_definition changes made outside Terraform (lifecycle.ignore_changes).

variable "name_prefix" {
  description = "Environment prefix, e.g. idp-dev (role/family names must match the CI roles' idp-<env>-* scopes)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase characters."
  }
}

variable "environment" {
  description = "Environment name, injected as APP_ENV."
  type        = string
}

variable "service_name" {
  description = "From the validated service manifest (metadata.name)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.service_name))
    error_message = "service_name must match the manifest naming rule."
  }
}

variable "image" {
  description = "Container image pinned by digest: <registry>/<repo>@sha256:<64 hex>. Tags are rejected."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.image))
    error_message = "image must be an ECR image referenced by immutable digest (…@sha256:<digest>), never a tag such as :latest."
  }
}

variable "ecr_repository_arn" {
  description = "The only repository the execution role may pull from."
  type        = string
}

variable "cpu" {
  description = "Fargate CPU units."
  type        = number
  validation {
    condition     = contains([256, 512, 1024], var.cpu)
    error_message = "cpu must be 256, 512 or 1024."
  }
}

variable "memory" {
  description = "Fargate memory (MiB), valid for the selected cpu."
  type        = number
  validation {
    condition = contains(lookup({
      "256"  = [512, 1024, 2048]
      "512"  = [1024, 2048, 3072, 4096]
      "1024" = [2048, 3072, 4096]
    }, tostring(var.cpu), []), var.memory)
    error_message = "memory is not a valid Fargate combination for the selected cpu."
  }
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be an unprivileged port (1024-65535)."
  }
}

variable "desired_count" {
  description = "Number of tasks."
  type        = number
  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 6
    error_message = "desired_count must be between 0 and 6."
  }
}

variable "cluster_arn" {
  description = "ECS cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the task security group."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the tasks."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Dev cost mode only (no NAT Gateway, SE-1). The production reference uses private subnets (false)."
  type        = bool
  default     = false
}

variable "alb_security_group_id" {
  description = "The task security group accepts traffic only from this security group."
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group the service registers into."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Boundary both service roles must carry."
  type        = string
}

variable "deployment" {
  description = "From the manifest's spec.deployment."
  type = object({
    minimum_healthy_percent  = number
    maximum_percent          = number
    circuit_breaker_rollback = bool
  })
}

variable "health_check_grace_period_seconds" {
  description = "Time ECS ignores failing ALB health checks after a task starts."
  type        = number
  default     = 30
}

variable "stop_timeout_seconds" {
  description = "SIGTERM -> SIGKILL grace period. Must exceed the app's graceful-shutdown timeout (20s)."
  type        = number
  default     = 30
  validation {
    condition     = var.stop_timeout_seconds >= 21 && var.stop_timeout_seconds <= 120
    error_message = "stop_timeout_seconds must be 21-120."
  }
}

variable "environment_variables" {
  description = "Plain, non-secret configuration (validated by the manifest policy)."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "Env var name -> PARTIAL Secrets Manager ARN (without the 6-character suffix), scoped to idp/<env>/<service>/ by the platform."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for arn in values(var.secret_arns) : can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:idp/", arn))])
    error_message = "secret_arns must reference Secrets Manager secrets under the idp/ namespace."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the service's log group."
  type        = number
}

variable "wait_for_steady_state" {
  description = "Make terraform apply wait until the deployment is healthy (deployment verification)."
  type        = bool
  default     = true
}
