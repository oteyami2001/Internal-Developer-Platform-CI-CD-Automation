# Environment stack (Phase 1: guardrails and naming only - NO resources yet).
#
# Phase 4 wires the modules in this order (see docs/architecture.md, "Terraform module plan"):
#   network -> security -> load-balancer -> ecs-cluster -> ecs-service (per catalog entry) ->
#   observability -> budgets
# Bootstrap-level resources (state bucket, GitHub OIDC roles, ECR) live in terraform/bootstrap.

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Applied to every resource through the provider's default_tags. Service manifests cannot
  # override these keys (platform/policy/platform-policy.yaml: reserved_tag_keys).
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "oteyami2001/Internal-Developer-Platform-CI-CD-Automation"
    CostCenter  = var.cost_center
  }
}

# Guard 2 of 2: fail the plan if the credentials belong to another account or the provider is
# pointed at another region, even if allowed_account_ids were removed from providers.tf.
data "aws_caller_identity" "current" {
  lifecycle {
    postcondition {
      condition     = self.account_id == var.aws_account_id
      error_message = "Credentials belong to a different AWS account than aws_account_id. Refusing to plan."
    }
  }
}

data "aws_region" "current" {
  lifecycle {
    postcondition {
      condition     = self.region == var.region
      error_message = "Provider region does not match var.region."
    }
  }
}
