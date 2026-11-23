# Offline tests for the ecs-service module (no AWS calls).

mock_provider "aws" {
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_data {
    target = data.aws_iam_policy_document.ecs_tasks_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"}}]}" }
  }
  override_resource {
    target          = aws_cloudwatch_log_group.this
    override_during = plan
    values          = { arn = "arn:aws:logs:us-east-2:111111111111:log-group:/idp/dev/sample-api" }
  }
}

variables {
  name_prefix              = "idp-dev"
  environment              = "dev"
  service_name             = "sample-api"
  image                    = "111111111111.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  ecr_repository_arn       = "arn:aws:ecr:us-east-2:111111111111:repository/idp/sample-api"
  cpu                      = 256
  memory                   = 512
  container_port           = 8080
  desired_count            = 1
  cluster_arn              = "arn:aws:ecs:us-east-2:111111111111:cluster/idp-dev"
  vpc_id                   = "vpc-12345678"
  subnet_ids               = ["subnet-aaaa", "subnet-bbbb"]
  assign_public_ip         = true
  alb_security_group_id    = "sg-alb"
  target_group_arn         = "arn:aws:elasticloadbalancing:us-east-2:111111111111:targetgroup/idp-dev-tg/0123456789abcdef"
  permissions_boundary_arn = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary"
  deployment               = { minimum_healthy_percent = 100, maximum_percent = 200, circuit_breaker_rollback = true }
  log_retention_days       = 7
}

run "hardened_container_definition" {
  command = plan

  assert {
    condition = alltrue([
      jsondecode(aws_ecs_task_definition.this.container_definitions)[0].user == "10001:10001",
      jsondecode(aws_ecs_task_definition.this.container_definitions)[0].readonlyRootFilesystem,
      jsondecode(aws_ecs_task_definition.this.container_definitions)[0].privileged == false,
      jsondecode(aws_ecs_task_definition.this.container_definitions)[0].linuxParameters.capabilities.drop == ["ALL"],
    ])
    error_message = "container must be non-root, read-only, unprivileged and drop all capabilities"
  }
  assert {
    condition     = strcontains(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image, "@sha256:")
    error_message = "image must be digest-pinned"
  }
  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
    } == { APP_ENV = "dev", LOG_LEVEL = "INFO", SERVICE_NAME = "sample-api" }
    error_message = "platform must inject APP_ENV, SERVICE_NAME, LOG_LEVEL"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].stopTimeout == 30
    error_message = "stop timeout must exceed the app's 20 s drain"
  }
  assert {
    condition     = aws_ecs_task_definition.this.family == "idp-dev-sample-api"
    error_message = "family must match the deploy role's task-definition/idp-dev-* scope"
  }
}

run "least_privilege_roles_with_boundary" {
  command = plan

  assert {
    condition = alltrue([
      aws_iam_role.execution.permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.task.permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.execution.name == "idp-dev-sample-api-exec",
      aws_iam_role.task.name == "idp-dev-sample-api-task",
    ])
    error_message = "both roles must carry the boundary and live in the idp-dev-* scope"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Resource if st.Sid == "PullOwnRepository"
    ]) == ["arn:aws:ecr:us-east-2:111111111111:repository/idp/sample-api"]
    error_message = "execution role may pull only from the service's own repository"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "secretsmanager")
    error_message = "no secret access when the service declares no secrets"
  }
}

run "network_and_deployment_safety" {
  command = plan

  assert {
    condition     = one(aws_security_group.task.ingress).security_groups == toset(["sg-alb"]) && try(length(one(aws_security_group.task.ingress).cidr_blocks), 0) == 0
    error_message = "tasks may receive traffic only from the ALB security group"
  }
  assert {
    condition     = one(aws_security_group.task.egress).from_port == 443 && one(aws_security_group.task.egress).to_port == 443
    error_message = "task egress must be HTTPS only"
  }
  assert {
    condition     = one(aws_ecs_service.this.deployment_circuit_breaker).enable && one(aws_ecs_service.this.deployment_circuit_breaker).rollback
    error_message = "deployment circuit breaker with rollback must be on"
  }
  assert {
    condition     = aws_ecs_service.this.launch_type == "FARGATE" && aws_ecs_service.this.wait_for_steady_state
    error_message = "Fargate, and apply waits for a healthy deployment"
  }
}

run "secrets_are_scoped" {
  command = plan
  variables {
    secret_arns = { DB_PASSWORD = "arn:aws:secretsmanager:us-east-2:111111111111:secret:idp/dev/sample-api/db" }
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Resource if st.Sid == "ReadOwnSecrets"
    ]) == ["arn:aws:secretsmanager:us-east-2:111111111111:secret:idp/dev/sample-api/db-??????"]
    error_message = "execution role may read only the declared secrets"
  }
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
  variables { memory = 4096 }
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
