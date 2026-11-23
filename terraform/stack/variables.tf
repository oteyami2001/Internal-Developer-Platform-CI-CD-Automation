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
  description = "AWS Region. Restricted to regions approved for this project (pending owner confirmation, see docs/deployment-plan.md)."
  type        = string
  validation {
    condition     = contains(["us-east-2", "us-east-1", "us-west-2"], var.region)
    error_message = "region is not on the approved list (us-east-2, us-east-1, us-west-2)."
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
  description = "E-mail address for SNS alarm and budget notifications."
  type        = string
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

variable "monthly_budget_usd" {
  description = "Monthly AWS Budgets threshold for this environment's tagged resources. Notifications only - it does not stop spending."
  type        = number
  default     = 25
  validation {
    condition     = var.monthly_budget_usd >= 1 && var.monthly_budget_usd <= 200
    error_message = "monthly_budget_usd must be between 1 and 200."
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
