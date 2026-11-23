# Validates a committed environment data file (terraform/envs/<env>/terraform.tfvars) against the
# stack's guardrails, offline. Run once per environment, passing that file:
#   terraform test -test-directory=tests/env-data -var-file=../envs/<env>/terraform.tfvars
# Identifying values are not in the tfvars (CI supplies them as TF_VAR_*), so fixtures stand in here.
# prod requires HTTPS, so a placeholder certificate ARN is supplied for prod only.

mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_data {
    target = data.aws_iam_policy.boundary
    values = { arn = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary" }
  }
  override_data {
    target = data.aws_ecr_repository.service
    values = { arn = "arn:aws:ecr:us-east-2:111111111111:repository/idp/sample-api" }
  }
  override_data {
    target = module.network.data.aws_availability_zones.available
    values = { names = ["us-east-2a", "us-east-2b", "us-east-2c"] }
  }
  override_data {
    target = module.network.data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
  override_data {
    target = module.observability.data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
  override_data {
    target = module.observability.data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_data {
    target = module.service[0].data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_data {
    target = module.service[0].data.aws_iam_policy_document.ecs_tasks_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  aws_account_id        = "111111111111"
  allowed_ingress_cidrs = ["203.0.113.10/32"]
  alert_email           = "alerts@example.com"
}

run "environment_data_passes_guardrails" {
  command = plan
  variables {
    certificate_arn = var.environment == "prod" ? "arn:aws:acm:us-east-2:111111111111:certificate/00000000-0000-0000-0000-000000000000" : null
    service = {
      service_name          = "sample-api"
      owner                 = "team-platform"
      environment           = var.environment
      container_port        = 8080
      cpu                   = 256
      memory                = 512
      desired_count         = var.environment == "prod" ? 2 : 1
      health_check          = { path = "/health", intervalSeconds = 30, healthyThreshold = 2, unhealthyThreshold = 3 }
      deployment            = { strategy = "rolling", circuitBreakerRollback = true, minimumHealthyPercent = 100, maximumPercent = 200 }
      environment_variables = {}
      secrets               = {}
      tags                  = {}
    }
  }
  assert {
    condition     = output.name_prefix == "idp-${var.environment}"
    error_message = "unexpected name prefix for ${var.environment}"
  }
}
