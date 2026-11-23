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
  }
  assert {
    condition     = output.name_prefix == "idp-${var.environment}"
    error_message = "unexpected name prefix for ${var.environment}"
  }
}
