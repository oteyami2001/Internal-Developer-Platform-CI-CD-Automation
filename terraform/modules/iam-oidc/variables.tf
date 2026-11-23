# GitHub Actions -> AWS federation: one role per job type, each trusting an EXACT OIDC subject.
#
#   role (per environment <e>)   trusted subject (StringEquals, no wildcards)   can do
#   ---------------------------  ---------------------------------------------  ------------------------------------------
#   <project>-<e>-github-plan    <prefix>:environment:<e>-plan                  Describe/List/Get + read state + lock file
#   <project>-<e>-github-apply   <prefix>:environment:<e>                       region-locked writes; IAM only with boundary
#   <project>-<e>-github-deploy  <prefix>:environment:<e>-deploy               register task definitions, update one cluster
#   <project>-github-image-push  <prefix>:ref:refs/heads/main                   push to <project>/* ECR repositories only
#
# No role trusts the `pull_request` subject (ADR 0003). <prefix> uses immutable IDs when the
# repository's OIDC customization says so (verified for this repository, ADR 0005).

variable "project" {
  description = "Resource name prefix (roles are <project>-...)."
  type        = string
}

variable "account_id" {
  description = "AWS account ID the roles live in."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

variable "region" {
  description = "Only Region the apply/deploy roles may change (aws:RequestedRegion)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the account's GitHub OIDC provider (shared, looked up by the caller)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the token.actions.githubusercontent.com provider."
  }
}

variable "github_owner" {
  description = "GitHub user or organization."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,39}$", var.github_owner))
    error_message = "github_owner must be a valid GitHub user/organization name."
  }
}

variable "github_repository" {
  description = "Repository name without the owner."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a repository name without the owner."
  }
}

variable "github_oidc_immutable_subject" {
  description = "Build subjects as repo:<owner>@<owner_id>/<repo>@<repo_id>:... (immutable IDs) instead of repo:<owner>/<repo>:..."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric owner ID (immutable subjects)."
  type        = string
  default     = null
}

variable "github_repository_id" {
  description = "Numeric repository ID (immutable subjects)."
  type        = string
  default     = null
  validation {
    condition     = !var.github_oidc_immutable_subject || (var.github_owner_id != null && var.github_repository_id != null)
    error_message = "github_owner_id and github_repository_id are required for immutable OIDC subjects."
  }
}

variable "environments" {
  description = "Environments whose plan/apply/deploy roles are created."
  type        = list(string)
  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : contains(["dev", "staging", "prod"], e)])
    error_message = "environments must be a non-empty subset of dev, staging, prod."
  }
}

variable "state_bucket_arn" {
  description = "Terraform state bucket. Roles get access to envs/<env>/* only."
  type        = string
}

variable "ecr_repository_prefix" {
  description = "ECR repositories the image-push and deploy roles may use: <prefix>* (e.g. \"idp/\")."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*/$", var.ecr_repository_prefix))
    error_message = "ecr_repository_prefix must look like \"idp/\"."
  }
}

variable "permissions_boundaries" {
  description = "Environment -> permissions boundary ARN that every role created by that environment's apply role must carry."
  type        = map(string)
  validation {
    condition     = alltrue([for e in var.environments : contains(keys(var.permissions_boundaries), e)])
    error_message = "Every environment needs a permissions boundary."
  }
  validation {
    condition     = alltrue([for arn in values(var.permissions_boundaries) : can(regex("^arn:aws:iam::[0-9]{12}:policy/", arn))])
    error_message = "permissions_boundaries values must be IAM policy ARNs."
  }
}

variable "protected_name_prefixes" {
  description = "Name/tag prefixes of OTHER projects sharing the account. The apply role is explicitly denied any action on them (ADR 0005)."
  type        = list(string)
  default     = []
}

variable "max_session_duration_seconds" {
  description = "Maximum role session length."
  type        = number
  default     = 3600
  validation {
    condition     = var.max_session_duration_seconds >= 900 && var.max_session_duration_seconds <= 3600
    error_message = "Sessions are limited to 15-60 minutes."
  }
}
