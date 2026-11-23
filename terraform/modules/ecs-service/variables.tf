# tflint-ignore-file: terraform_unused_declarations # SKELETON: inputs are the contract; resources arrive in Phase 3/4.
# Remove this line when the configuration gets resources (enforced by tests/platform/test_repo_hygiene.py).

# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 4)
#
# Planned resources:
#   aws_ecs_task_definition  (Fargate, awsvpc, non-root, read-only root FS, no privileged mode)
#   aws_ecs_service          (rolling deploy, deployment circuit breaker + rollback, ALB target)
#   aws_security_group       (task SG: ingress ONLY from the ALB SG on container_port)
#   aws_cloudwatch_log_group (awslogs driver, bounded retention)
#
# Hard-coded by design (not inputs): readonlyRootFilesystem = true, privileged = false,
# user = "10001", launch type FARGATE, platform version LATEST. A service manifest cannot turn
# them off because there is no variable to set.

variable "name_prefix" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase characters."
  }
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

variable "cpu" {
  type = number
  validation {
    condition     = contains([256, 512, 1024], var.cpu)
    error_message = "cpu must be 256, 512 or 1024."
  }
}

variable "memory" {
  type = number
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
  type = number
  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be an unprivileged port (1024-65535)."
  }
}

variable "desired_count" {
  type = number
  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 6
    error_message = "desired_count must be between 0 and 6."
  }
}

variable "cluster_arn" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "assign_public_ip" {
  description = "Dev cost mode only (no NAT Gateway). Production reference uses private subnets (false)."
  type        = bool
  default     = false
}

variable "alb_security_group_id" {
  description = "The task security group accepts traffic only from this security group."
  type        = string
}

variable "target_group_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "health_check" {
  type = object({
    path                = string
    interval_seconds    = number
    healthy_threshold   = number
    unhealthy_threshold = number
  })
}

variable "deployment" {
  type = object({
    minimum_healthy_percent  = number
    maximum_percent          = number
    circuit_breaker_rollback = bool
  })
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
  description = "Env var name -> Secrets Manager ARN, scoped to idp/<env>/<service>/ by the platform."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for arn in values(var.secret_arns) : can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:idp/", arn))])
    error_message = "secret_arns must reference Secrets Manager secrets under the idp/ namespace."
  }
}

variable "log_retention_days" {
  type = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
