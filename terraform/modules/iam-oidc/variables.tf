# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 3, bootstrap)
#
# Planned resources:
#   aws_iam_openid_connect_provider (token.actions.githubusercontent.com) - or reuse an existing one
#   Four roles, each trusting an EXACT OIDC subject (StringEquals, no wildcards) and aud=sts.amazonaws.com:
#
#   role          trusted subject                                        permissions
#   ------------  -----------------------------------------------------  -------------------------------------
#   plan          repo:<owner>/<repo>:environment:<env>-plan             describe/list only + state read/lock
#   apply         repo:<owner>/<repo>:environment:<env>                  scoped writes, region-locked, boundary-enforced IAM
#   image-push    repo:<owner>/<repo>:ref:refs/heads/main                push to ECR repositories only
#   deploy        repo:<owner>/<repo>:environment:<env>-deploy           ecs:RegisterTaskDefinition/UpdateService on one cluster
#
# Deliberate change from the previous project: NO role trusts the `pull_request` subject. PR
# workflows run offline checks only; plans run from a protected "<env>-plan" environment.

variable "project" {
  type = string
}

variable "github_owner" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,39}$", var.github_owner))
    error_message = "github_owner must be a valid GitHub user/organization name."
  }
}

variable "github_repository" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a repository name without the owner."
  }
}

variable "create_oidc_provider" {
  description = "false if the account already has the GitHub OIDC provider (one per account). In the shared account it is owned by the AIOps project and only looked up here."
  type        = bool
  default     = false
}

variable "github_oidc_immutable_subject" {
  description = "Build subjects as repo:<owner>@<owner_id>/<repo>@<repo_id>:... (immutable IDs) instead of repo:<owner>/<repo>:..."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  type    = string
  default = null
}

variable "github_repository_id" {
  type    = string
  default = null
  validation {
    condition     = !var.github_oidc_immutable_subject || (var.github_owner_id != null && var.github_repository_id != null)
    error_message = "github_owner_id and github_repository_id are required for immutable OIDC subjects."
  }
}

variable "environments" {
  description = "Environments whose plan/apply/deploy roles are created."
  type        = list(string)
  validation {
    condition     = alltrue([for e in var.environments : contains(["dev", "staging", "prod"], e)])
    error_message = "environments may only contain dev, staging, prod."
  }
}

variable "region" {
  description = "Write permissions are conditioned on aws:RequestedRegion = region."
  type        = string
}

variable "state_bucket_arn" {
  type = string
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "permissions_boundary_arn" {
  description = "Every role created by the apply role must carry this boundary."
  type        = string
}

variable "max_session_duration_seconds" {
  type    = number
  default = 3600
  validation {
    condition     = var.max_session_duration_seconds >= 900 && var.max_session_duration_seconds <= 3600
    error_message = "Sessions are limited to 15-60 minutes."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
