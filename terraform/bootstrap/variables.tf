# BOOTSTRAP (Phase 1 skeleton - implemented and applied ONLY after approval in Phase 3)
#
# One-time, account-level foundation applied by an administrator from a workstation, with local
# state first and then migrated into the bucket it creates:
#   - S3 state bucket: versioning, SSE, public access block, TLS-only + deny-delete bucket policy
#   - GitHub OIDC provider and the plan / apply / image-push / deploy roles (module iam-oidc)
#   - Workload permissions boundary (module security)
#   - ECR repositories for catalog services (module ecr)
#   - Account-level AWS Budget (module budgets)
# Everything else is created by terraform/stack through the approval-gated pipeline.

variable "project" {
  type    = string
  default = "idp"
}

variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  type = string
  validation {
    condition     = contains(["us-east-2", "us-east-1", "us-west-2"], var.region)
    error_message = "region is not on the approved list."
  }
}

variable "github_owner" {
  type    = string
  default = "oteyami2001"
}

variable "github_repository" {
  type    = string
  default = "Internal-Developer-Platform-CI-CD-Automation"
}

variable "create_oidc_provider" {
  description = "Set false if `aws iam list-open-id-connect-providers` already shows token.actions.githubusercontent.com."
  type        = bool
  default     = true
}

variable "alert_email" {
  type = string
}

variable "account_monthly_budget_usd" {
  type    = number
  default = 30
  validation {
    condition     = var.account_monthly_budget_usd >= 1 && var.account_monthly_budget_usd <= 200
    error_message = "account_monthly_budget_usd must be 1-200."
  }
}
