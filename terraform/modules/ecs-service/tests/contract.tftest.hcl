# Offline contract tests for the ecs-service module interface (no AWS calls).

mock_provider "aws" {}

variables {
  name_prefix           = "idp-dev"
  service_name          = "sample-api"
  image                 = "111111111111.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  cpu                   = 256
  memory                = 512
  container_port        = 8080
  desired_count         = 1
  cluster_arn           = "arn:aws:ecs:us-east-2:111111111111:cluster/idp-dev"
  subnet_ids            = ["subnet-aaaa", "subnet-bbbb"]
  alb_security_group_id = "sg-alb"
  target_group_arn      = "arn:aws:elasticloadbalancing:us-east-2:111111111111:targetgroup/idp-dev-sample-api/0123456789abcdef"
  execution_role_arn    = "arn:aws:iam::111111111111:role/idp-dev-sample-api-exec"
  task_role_arn         = "arn:aws:iam::111111111111:role/idp-dev-sample-api-task"
  health_check          = { path = "/health", interval_seconds = 30, healthy_threshold = 2, unhealthy_threshold = 3 }
  deployment            = { minimum_healthy_percent = 100, maximum_percent = 200, circuit_breaker_rollback = true }
  log_retention_days    = 7
}

run "digest_pinned_image_is_accepted" {
  command = plan
}

run "mutable_latest_tag_is_rejected" {
  command = plan
  variables { image = "111111111111.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api:latest" }
  expect_failures = [var.image]
}

run "non_ecr_registry_is_rejected" {
  command = plan
  variables { image = "docker.io/library/nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000" }
  expect_failures = [var.image]
}

run "invalid_fargate_size_is_rejected" {
  command = plan
  variables { memory = 4096 } # 4 GiB is not valid with 0.25 vCPU
  expect_failures = [var.memory]
}

run "privileged_port_is_rejected" {
  command = plan
  variables { container_port = 80 }
  expect_failures = [var.container_port]
}

run "foreign_secret_namespace_is_rejected" {
  command = plan
  variables { secret_arns = { DB_PASSWORD = "arn:aws:secretsmanager:us-east-2:111111111111:secret:other-team/db-AbCdEf" } }
  expect_failures = [var.secret_arns]
}

run "stop_timeout_shorter_than_app_drain_is_rejected" {
  command = plan
  variables { stop_timeout_seconds = 10 }
  expect_failures = [var.stop_timeout_seconds]
}
