data "aws_region" "current" {}

locals {
  family    = "${var.name_prefix}-${var.service_name}"
  log_group = "/${replace(var.name_prefix, "-", "/")}/${var.service_name}"

  # Platform-injected variables win over manifest variables (the manifest policy already rejects them).
  environment = merge(var.environment_variables, {
    APP_ENV      = var.environment
    SERVICE_NAME = var.service_name
    LOG_LEVEL    = "INFO"
  })
}

#trivy:ignore:AVD-AWS-0017 AWS-owned encryption at rest; a customer managed KMS key adds $1/month.
resource "aws_cloudwatch_log_group" "this" {
  # checkov:skip=CKV_AWS_158:Encrypted at rest with the CloudWatch Logs service key; a CMK adds $1/month (cost model).
  # checkov:skip=CKV_AWS_338:Retention is bounded by var.log_retention_days (dev: 7 days) to control cost.
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------------------------
# IAM: execution role (ECS agent: pull image, write logs, read own secrets) and task role (the
# application's AWS identity: no permissions - the sample app calls no AWS API). Both carry the
# environment's permissions boundary, which the apply role cannot create roles without.
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${local.family}-exec"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "execution" {
  name = "pull-image-write-logs"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "EcrLogin"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"] # no resource-level permissions
          Resource = ["*"]
        },
        {
          Sid      = "PullOwnRepository"
          Effect   = "Allow"
          Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
          Resource = [var.ecr_repository_arn]
        },
        {
          Sid      = "WriteOwnLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = ["${aws_cloudwatch_log_group.this.arn}:*"]
        },
      ],
      length(var.secret_arns) == 0 ? [] : [{
        Sid      = "ReadOwnSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [for arn in sort(values(var.secret_arns)) : "${arn}-??????"] # + Secrets Manager's random suffix
      }],
    )
  })
}

resource "aws_iam_role" "task" {
  name                 = "${local.family}-task"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# ---------------------------------------------------------------------------------------------
# Network: tasks accept traffic only from the ALB, and only reach out over HTTPS.
# ---------------------------------------------------------------------------------------------
resource "aws_security_group" "task" {
  name        = "${local.family}-task"
  description = "${var.service_name} tasks: ingress from the ALB only; HTTPS egress (ECR, CloudWatch Logs)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From the load balancer only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  #trivy:ignore:AVD-AWS-0104 HTTPS egress to AWS public endpoints (ECR, CloudWatch Logs) without NAT or VPC endpoints: dev cost mode SE-1.
  egress {
    description = "HTTPS to AWS APIs (ECR, CloudWatch Logs); no NAT/VPC endpoints in dev (SE-1)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.family}-task" }
}

# ---------------------------------------------------------------------------------------------
# Task definition and service
# ---------------------------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = local.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = var.service_name
    image                  = var.image
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    privileged             = false
    stopTimeout            = var.stop_timeout_seconds
    portMappings           = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment            = [for k in sort(keys(local.environment)) : { name = k, value = local.environment[k] }]
    secrets                = [for k in sort(keys(var.secret_arns)) : { name = k, valueFrom = var.secret_arns[k] }]
    linuxParameters        = { capabilities = { drop = ["ALL"] } }
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status == 200 else 1)"]
      interval    = 15
      timeout     = 3
      retries     = 3
      startPeriod = 10
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = var.service_name
        mode                  = "non-blocking"
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  # checkov:skip=CKV_AWS_333:Public IP only in dev cost mode without NAT (SE-1); inbound is limited to the ALB security group.
  name                              = var.service_name
  cluster                           = var.cluster_arn
  task_definition                   = aws_ecs_task_definition.this.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  propagate_tags                    = "SERVICE"
  enable_ecs_managed_tags           = true
  health_check_grace_period_seconds = var.health_check_grace_period_seconds
  wait_for_steady_state             = var.wait_for_steady_state

  deployment_minimum_healthy_percent = var.deployment.minimum_healthy_percent
  deployment_maximum_percent         = var.deployment.maximum_percent

  deployment_circuit_breaker {
    enable   = true
    rollback = var.deployment.circuit_breaker_rollback
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  lifecycle {
    # Releases are task-definition revisions registered by app-deploy.yml (Phase 5).
    ignore_changes = [task_definition]
  }
}
