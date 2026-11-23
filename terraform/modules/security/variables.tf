# Workload permissions boundary for one environment.
#
# A boundary is a CEILING: a role's effective permissions are the intersection of the boundary and
# its own policies. The environment's apply role can only create or change roles that carry this
# boundary (iam-oidc: ManageEnvironmentRolesWithBoundaryOnly). So even a role that someone attaches
# AdministratorAccess to cannot write IAM, touch Organizations/billing or tamper with CloudTrail.
# Per-service ECS execution/task roles are created with it by the ecs-service module (Phase 4).

variable "project" {
  description = "Resource name prefix."
  type        = string
}

variable "environment" {
  description = "Environment this boundary applies to."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "region" {
  description = "Region of the workload's secrets."
  type        = string
}
