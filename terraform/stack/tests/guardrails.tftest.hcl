# Offline tests (mocked AWS provider, no credentials, no API calls): `terraform test`.
# They prove the guardrails reject insecure or mis-targeted configurations at plan time.

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
  environment           = "dev"
  aws_account_id        = "111111111111"
  region                = "us-east-2"
  allowed_ingress_cidrs = ["203.0.113.10/32"]
  alert_email           = "alerts@example.com"
}

run "dev_defaults_are_valid" {
  command = plan
  assert {
    condition     = output.name_prefix == "idp-dev"
    error_message = "unexpected name prefix"
  }
  assert {
    condition     = output.tags["Environment"] == "dev" && output.tags["ManagedBy"] == "terraform"
    error_message = "platform tags missing"
  }
}

run "staging_is_valid" {
  command = plan
  variables {
    environment        = "staging"
    log_retention_days = 14
  }
  assert {
    condition     = output.name_prefix == "idp-staging"
    error_message = "unexpected name prefix"
  }
}

run "prod_with_https_is_valid" {
  command = plan
  variables {
    environment           = "prod"
    certificate_arn       = "arn:aws:acm:us-east-2:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    allowed_ingress_cidrs = ["0.0.0.0/0"] # public HTTPS is acceptable for prod
    log_retention_days    = 30
  }
}

run "rejects_unknown_environment" {
  command = plan
  variables { environment = "qa" }
  expect_failures = [var.environment]
}

run "rejects_unapproved_region" {
  command = plan
  variables { region = "eu-west-3" }
  expect_failures = [var.region]
}

run "rejects_malformed_account_id" {
  command = plan
  variables { aws_account_id = "1234" }
  expect_failures = [var.aws_account_id]
}

run "rejects_wrong_account_credentials" {
  # Credentials (mocked as 111111111111) do not belong to the configured account.
  command = plan
  variables { aws_account_id = "222222222222" }
  expect_failures = [data.aws_caller_identity.current]
}

run "rejects_internet_open_http" {
  command = plan
  variables { allowed_ingress_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_wide_http_ranges" {
  command = plan
  variables { allowed_ingress_cidrs = ["203.0.113.0/24"] }
  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_prod_without_https" {
  command = plan
  variables {
    environment        = "prod"
    log_retention_days = 30
  }
  expect_failures = [var.certificate_arn]
}

run "rejects_long_non_prod_log_retention" {
  command = plan
  variables { log_retention_days = 365 }
  expect_failures = [var.log_retention_days]
}

run "rejects_oversized_budget" {
  command = plan
  variables { monthly_budget_usd = 5000 }
  expect_failures = [var.monthly_budget_usd]
}

run "rejects_invalid_vpc_cidr" {
  command = plan
  variables { vpc_cidr = "10.0.0.0/8" }
  expect_failures = [var.vpc_cidr]
}

run "rejects_invalid_alert_email" {
  command = plan
  variables { alert_email = "not-an-email" }
  expect_failures = [var.alert_email]
}
