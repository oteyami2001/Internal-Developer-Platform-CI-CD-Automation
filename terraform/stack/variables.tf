# One root configuration shared by dev, staging and prod. Environments differ ONLY in data
# (terraform/envs/<env>/terraform.tfvars + backend.hcl), which keeps them structurally identical:
# what is tested in dev is what is promoted to prod.
#
# Values that identify a person or account (account ID, alert e-mail, the operator's /32) are NOT
# committed: CI passes them as TF_VAR_* from GitHub environment variables.

variable "project" {
  description = "Short project prefix used in resource names."
  type        = string
  default     = "idp"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.project))
    error_message = "project must be 2-8 lowercase alphanumeric characters (keeps AWS names under length limits)."
  }
}

variable "environment" {
  description = "Logical environment."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_account_id" {
  description = "The ONLY AWS account this configuration may touch."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS Region. us-east-2 only: the shared account's Organization SCP denies regional services in us-east-1 (ADR 0005)."
  type        = string
  validation {
    condition     = contains(["us-east-2"], var.region)
    error_message = "region must be us-east-2 (the only Region approved for the shared account; us-east-1 is denied by SCP)."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR block (/16 to /24)."
  type        = string
  default     = "10.40.0.0/20"
  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24
    )
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /24."
  }
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. Required for prod; optional (HTTP + /32 ingress) for dev/staging demos."
  type        = string
  default     = null
  validation {
    condition     = var.certificate_arn == null || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]{36}$", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
  validation {
    condition     = var.environment != "prod" || var.certificate_arn != null
    error_message = "prod requires HTTPS: set certificate_arn."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the load balancer. Without HTTPS, only single-host /32 ranges are accepted."
  type        = list(string)
  sensitive   = true # the operator's home IP: personal data, kept out of plan output and CI logs
  validation {
    condition     = length(var.allowed_ingress_cidrs) >= 1 && length(var.allowed_ingress_cidrs) <= 10
    error_message = "Provide between 1 and 10 ingress CIDRs."
  }
  validation {
    condition     = alltrue([for c in var.allowed_ingress_cidrs : can(cidrnetmask(c))])
    error_message = "Every allowed_ingress_cidrs entry must be a valid IPv4 CIDR."
  }
  validation {
    # Plain-HTTP endpoints must never be open to the internet.
    condition = var.certificate_arn != null || alltrue([
      for c in var.allowed_ingress_cidrs : endswith(c, "/32")
    ])
    error_message = "Without certificate_arn (HTTP only), allowed_ingress_cidrs must be /32 host addresses - 0.0.0.0/0 is rejected."
  }
}

variable "alert_email" {
  description = "E-mail address for SNS alarm notifications."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[a-zA-Z]{2,}$", trimspace(var.alert_email)))
    error_message = "alert_email must be a valid e-mail address."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Non-prod is capped at 30 days to control cost."
  type        = number
  default     = 7
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value (1, 3, 5, 7, 14, 30, 60, 90, 180, 365)."
  }
  validation {
    condition     = var.environment == "prod" || var.log_retention_days <= 30
    error_message = "Non-prod environments may keep logs for at most 30 days."
  }
}

variable "cost_center" {
  description = "Cost-allocation tag value."
  type        = string
  default     = "platform-demo"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,64}$", var.cost_center))
    error_message = "cost_center must be 1-64 characters of letters, digits, '.', '_' or '-'."
  }
}

# ---------------------------------------------------------------------------------------------
# Workload (Phase 4): one service per environment in the MVP, rendered from its validated manifest
# by `scripts/validate_service.py --render <env> apps/<svc>/service.yaml` (CI writes it to a
# -var-file; it is never hand-written).
# ---------------------------------------------------------------------------------------------
variable "service" {
  description = "Effective service settings rendered from the validated service manifest."
  type = object({
    service_name   = string
    owner          = string
    environment    = string
    container_port = number
    cpu            = number
    memory         = number
    desired_count  = number
    health_check = object({
      path               = string
      intervalSeconds    = number
      healthyThreshold   = number
      unhealthyThreshold = number
    })
    deployment = object({
      strategy               = string
      circuitBreakerRollback = bool
      minimumHealthyPercent  = number
      maximumPercent         = number
    })
    environment_variables = map(string)
    secrets               = map(string) # env var -> Secrets Manager secret NAME (idp/<env>/<service>/<name>)
    tags                  = map(string)
  })
  validation {
    condition     = var.service.environment == var.environment
    error_message = "The rendered service manifest is for a different environment."
  }
  validation {
    condition     = alltrue([for name in values(var.service.secrets) : startswith(name, "${var.project}/${var.environment}/${var.service.service_name}/")])
    error_message = "Secrets must live under <project>/<env>/<service>/."
  }
}

variable "service_image" {
  description = "Digest-pinned image to run. null = no ECS service yet (infrastructure only; Phase 5 publishes the first image)."
  type        = string
  default     = null
  validation {
    condition     = var.service_image == null || can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.service_image))
    error_message = "service_image must be an ECR image referenced by digest (…@sha256:<64 hex>), never a tag."
  }
}
