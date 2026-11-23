# tflint-ignore-file: terraform_unused_declarations # SKELETON: inputs are the contract; resources arrive in Phase 3/4.
# Remove this line when the configuration gets resources (enforced by tests/platform/test_repo_hygiene.py).

# BOOTSTRAP (Phase 1 skeleton - implemented and applied ONLY after approval in Phase 3)
#
# One-time, account-level foundation applied by an administrator from a workstation, with local
# state first and then migrated into the bucket it creates:
#   - S3 state bucket: versioning, SSE, public access block, TLS-only + deny-delete bucket policy
#   - plan / apply / image-push / deploy roles (module iam-oidc)
#   - Workload permissions boundary (module security)
#   - ECR repositories for catalog services (module ecr)
#   - Project-scoped AWS Budget (module budgets, filtered on Project=idp)
# Everything else is created by terraform/stack through the approval-gated pipeline.
#
# SHARED ACCOUNT (ADR 0005): the account also holds the AIOps project's retained bootstrap
# (aiops-* state bucket, roles, boundary, ECR repository, account-wide budget) and the account's
# single GitHub OIDC provider. This configuration only READS the OIDC provider (data source) and
# never manages, imports or modifies any aiops-* resource.

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
  type    = string
  default = "us-east-2"
  validation {
    condition     = contains(["us-east-2"], var.region)
    error_message = "region must be us-east-2 (us-east-1 is denied by the Organization SCP)."
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
  description = "false: the shared account already has the GitHub OIDC provider (created by the AIOps project). It is looked up, never managed here, so destroying this project can never break the other one."
  type        = bool
  default     = false
}

variable "github_oidc_immutable_subject" {
  description = "true: the repository's OIDC subject uses immutable IDs. Verified 2026-11-23 via GET repos/{repo}/actions/oidc/customization/sub: use_immutable_subject=true, prefix repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID used in immutable OIDC subjects. Not a secret."
  type        = string
  default     = "157901928"
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID used in immutable OIDC subjects (read from the GitHub API 2026-11-23). Not a secret."
  type        = string
  default     = "1465573837"
  validation {
    condition     = var.github_repository_id == null || can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be numeric."
  }
  validation {
    condition     = !var.github_oidc_immutable_subject || var.github_repository_id != null
    error_message = "github_repository_id is required when github_oidc_immutable_subject is true."
  }
}

variable "alert_email" {
  type = string
}

# The account-wide $30 budget already exists (aiops-account-monthly) and covers this project's
# spend too, so no second account-wide budget is created (it would only duplicate alerts).
variable "project_monthly_budget_usd" {
  description = "Budget for resources tagged Project=idp. Requires the Project tag to be activated as a cost-allocation tag (up to 24 h)."
  type        = number
  default     = 25
  validation {
    condition     = var.project_monthly_budget_usd >= 1 && var.project_monthly_budget_usd <= 200
    error_message = "project_monthly_budget_usd must be 1-200."
  }
}
