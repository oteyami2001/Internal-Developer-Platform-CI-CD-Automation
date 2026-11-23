# Offline tests (mocked AWS provider, no credentials, no API calls): `terraform test`.
# They prove the guardrails reject insecure or mis-targeted configurations at plan time, and that
# the environment wiring is what docs/architecture.md describes.

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
  environment           = "dev"
  aws_account_id        = "111111111111"
  region                = "us-east-2"
  allowed_ingress_cidrs = ["203.0.113.10/32"]
  alert_email           = "alerts@example.com"
  # Exactly what `scripts/validate_service.py --render dev apps/sample-api/service.yaml` produces.
  service = {
    service_name          = "sample-api"
    owner                 = "team-platform"
    environment           = "dev"
    container_port        = 8080
    cpu                   = 256
    memory                = 512
    desired_count         = 1
    health_check          = { path = "/health", intervalSeconds = 30, healthyThreshold = 2, unhealthyThreshold = 3 }
    deployment            = { strategy = "rolling", circuitBreakerRollback = true, minimumHealthyPercent = 100, maximumPercent = 200 }
    environment_variables = {}
    secrets               = {}
    tags                  = { cost-center = "platform-demo" }
  }
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
    service            = merge(var.service, { environment = "staging" })
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
    service               = merge(var.service, { environment = "prod" })
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

run "rejects_scp_blocked_us_east_1" {
  command = plan
  variables { region = "us-east-1" }
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
    service            = merge(var.service, { environment = "prod" })
  }
  expect_failures = [var.certificate_arn]
}

run "rejects_long_non_prod_log_retention" {
  command = plan
  variables { log_retention_days = 365 }
  expect_failures = [var.log_retention_days]
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

run "infrastructure_only_until_an_image_exists" {
  command = plan

  assert {
    condition     = length(module.service) == 0 && output.service_deployed == false
    error_message = "no ECS service may be created before Phase 5 publishes a digest-pinned image"
  }
  assert {
    condition     = output.ecs_cluster_name == "idp-dev"
    error_message = "cluster must match the deploy role scope"
  }
}

run "service_runs_hardened_in_dev_cost_mode" {
  command = plan
  variables {
    service_image = "111111111111.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  }

  assert {
    condition     = length(module.service) == 1 && output.service_deployed
    error_message = "service must be created once an image digest is supplied"
  }
}

run "rejects_mutable_image_tag" {
  command = plan
  variables {
    service_image = "111111111111.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api:latest"
  }
  expect_failures = [var.service_image]
}

run "rejects_service_rendered_for_another_environment" {
  command = plan
  variables {
    service = merge(var.service, { environment = "prod" })
  }
  expect_failures = [var.service]
}

run "rejects_secrets_outside_the_service_namespace" {
  command = plan
  variables {
    service = merge(var.service, { secrets = { DB_DSN = "idp/dev/other-service/db" } })
  }
  expect_failures = [var.service]
}
