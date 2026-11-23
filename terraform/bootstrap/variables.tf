# BOOTSTRAP - one-time, account-level foundation (Phase 3).
#
# Applied by an administrator from AWS CloudShell (us-east-2), never by CI, following
# docs/bootstrap-runbook.md: local state first, then migrated into the bucket it creates.
#   - S3 state bucket: versioned, SSE-KMS, public access blocked, TLS-only policy
#   - CloudTrail: single-Region management-events trail to its own S3 bucket (owner decision)
#   - Workload permissions boundary per environment (module security)
#   - GitHub OIDC roles: plan / apply / deploy per environment + image push (module iam-oidc)
#   - ECR repositories for catalog services (module ecr)
#   - Project-scoped AWS Budget (module budgets, filtered on Project=idp)
# Everything else is created by terraform/stack through the approval-gated pipeline.
#
# SHARED ACCOUNT (ADR 0005): the account also holds the AIOps project's retained bootstrap
# (aiops-* state bucket, roles, boundary, ECR repository, account-wide budget) and the account's
# single GitHub OIDC provider. This configuration only READS the OIDC provider (data source) and
# never manages, imports or modifies any aiops-* resource.

variable "project" {
  description = "Resource name prefix."
  type        = string
  default     = "idp"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.project))
    error_message = "project must be 2-8 lowercase alphanumeric characters."
  }
}

variable "aws_account_id" {
  description = "The ONLY AWS account this configuration may touch (passed at plan time, never committed)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS Region (us-east-1 is denied by the Organization SCP)."
  type        = string
  default     = "us-east-2"
  validation {
    condition     = contains(["us-east-2"], var.region)
    error_message = "region must be us-east-2 (us-east-1 is denied by the Organization SCP)."
  }
}

variable "environments" {
  description = "Environments whose CI roles and boundaries are created. Only dev until staging/prod are approved."
  type        = list(string)
  default     = ["dev"]
  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : contains(["dev", "staging", "prod"], e)])
    error_message = "environments must be a non-empty subset of dev, staging, prod."
  }
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository."
  type        = string
  default     = "oteyami2001"
}

variable "github_repository" {
  description = "Repository name without the owner."
  type        = string
  default     = "Internal-Developer-Platform-CI-CD-Automation"
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

variable "protected_name_prefixes" {
  description = "Other projects sharing the account. The apply roles are explicitly denied any action on resources tagged or named with these (ADR 0005)."
  type        = list(string)
  default     = ["aiops"]
}

variable "ecr_repositories" {
  description = "ECR repositories for catalog services (<project>/<service>)."
  type = map(object({
    max_images = optional(number, 20)
  }))
  default = { "idp/sample-api" = {} }
}

variable "alert_email" {
  description = "Budget alert recipient. Passed at plan time (TF_VAR_alert_email), never committed."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[a-zA-Z]{2,}$", trimspace(var.alert_email)))
    error_message = "alert_email must be a valid e-mail address."
  }
}

# The account-wide $30 budget already exists (aiops-account-monthly) and covers this project's
# spend too, so no second account-wide budget is created (it would only duplicate alerts).
variable "project_monthly_budget_usd" {
  description = "Budget for resources tagged Project=idp (owner decision 2026-11-23: 25 USD). Requires the Project tag to be activated as a cost allocation tag in the management account."
  type        = number
  default     = 25
  validation {
    condition     = var.project_monthly_budget_usd >= 1 && var.project_monthly_budget_usd <= 200
    error_message = "project_monthly_budget_usd must be 1-200."
  }
}

variable "cloudtrail_retention_days" {
  description = "Days to keep CloudTrail log files in S3 (owner decision 2026-11-23: trail enabled)."
  type        = number
  default     = 365
  validation {
    condition     = var.cloudtrail_retention_days >= 90 && var.cloudtrail_retention_days <= 2555
    error_message = "cloudtrail_retention_days must be 90-2555 (90 days is what Event history already gives for free)."
  }
}
