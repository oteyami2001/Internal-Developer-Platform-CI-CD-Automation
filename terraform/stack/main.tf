# Environment stack: everything one environment runs, applied only through terraform-apply.yml
# (the environment's apply role, after a reviewed plan and an approval).
#
#   network -> load-balancer -> ecs-cluster -> ecs-service (once an image exists) -> observability
#
# Bootstrap-level resources (state bucket, CI roles, permissions boundary, ECR, budget) live in
# terraform/bootstrap and are only READ here.

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

  deploy_service = var.service_image != null

  # Secret NAMES from the manifest -> partial Secrets Manager ARNs (ECS resolves the version suffix).
  secret_arns = {
    for env_var, name in var.service.secrets :
    env_var => "arn:aws:secretsmanager:${var.region}:${var.aws_account_id}:secret:${name}"
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

# Created by terraform/bootstrap. Reading them fails the plan early if the bootstrap is missing.
data "aws_iam_policy" "boundary" {
  arn = "arn:aws:iam::${var.aws_account_id}:policy/${local.name_prefix}-workload-boundary"
}

data "aws_ecr_repository" "service" {
  name = "${var.project}/${var.service.service_name}"
}

module "network" {
  source = "../modules/network"

  name_prefix              = local.name_prefix
  vpc_cidr                 = var.vpc_cidr
  log_retention_days       = var.log_retention_days
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
}

module "load_balancer" {
  source = "../modules/load-balancer"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  vpc_cidr              = module.network.vpc_cidr
  public_subnet_ids     = module.network.public_subnet_ids
  certificate_arn       = var.certificate_arn
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  target_port           = var.service.container_port
  health_check = {
    path                = var.service.health_check.path
    interval_seconds    = var.service.health_check.intervalSeconds
    healthy_threshold   = var.service.health_check.healthyThreshold
    unhealthy_threshold = var.service.health_check.unhealthyThreshold
  }
  enable_deletion_protection = var.environment == "prod"
}

module "ecs_cluster" {
  source = "../modules/ecs-cluster"

  name_prefix        = local.name_prefix
  container_insights = var.environment == "prod" ? "enabled" : "disabled"
}

module "service" {
  source = "../modules/ecs-service"
  count  = local.deploy_service ? 1 : 0

  name_prefix        = local.name_prefix
  environment        = var.environment
  service_name       = var.service.service_name
  image              = var.service_image
  ecr_repository_arn = data.aws_ecr_repository.service.arn
  cpu                = var.service.cpu
  memory             = var.service.memory
  container_port     = var.service.container_port
  desired_count      = var.service.desired_count
  cluster_arn        = module.ecs_cluster.cluster_arn
  vpc_id             = module.network.vpc_id
  # Dev cost mode (SE-1): public subnets + public IP, no NAT. Production reference: private subnets.
  subnet_ids               = module.network.public_subnet_ids
  assign_public_ip         = true
  alb_security_group_id    = module.load_balancer.security_group_id
  target_group_arn         = module.load_balancer.target_group_arn
  permissions_boundary_arn = data.aws_iam_policy.boundary.arn
  deployment = {
    minimum_healthy_percent  = var.service.deployment.minimumHealthyPercent
    maximum_percent          = var.service.deployment.maximumPercent
    circuit_breaker_rollback = var.service.deployment.circuitBreakerRollback
  }
  environment_variables = var.service.environment_variables
  secret_arns           = local.secret_arns
  log_retention_days    = var.log_retention_days
}

module "observability" {
  source = "../modules/observability"

  name_prefix             = local.name_prefix
  alert_email             = var.alert_email
  cluster_name            = module.ecs_cluster.cluster_name
  service_name            = local.deploy_service ? var.service.service_name : null
  alb_arn_suffix          = module.load_balancer.alb_arn_suffix
  target_group_arn_suffix = module.load_balancer.target_group_arn_suffix
  log_retention_days      = var.log_retention_days
}
