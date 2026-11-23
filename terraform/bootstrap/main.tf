provider "aws" {
  region = var.region

  # Guard 1 of 2 against the wrong account: refuse to run anywhere else. Guard 2 is the
  # caller-identity postcondition below.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project    = var.project
    Component  = "bootstrap"
    ManagedBy  = "terraform"
    Repository = "${var.github_owner}/${var.github_repository}"
  }

  state_bucket = "${var.project}-tfstate-${var.aws_account_id}-${var.region}"
  trail_bucket = "${var.project}-cloudtrail-${var.aws_account_id}-${var.region}"
  trail_name   = "${var.project}-management-events"
}

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

# ---------------------------------------------------------------------------------------------
# GitHub OIDC provider: shared with the AIOps project, so it is looked up, not managed (ADR 0005).
# ---------------------------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

module "boundary" {
  source   = "../modules/security"
  for_each = toset(var.environments)

  project     = var.project
  environment = each.key
  account_id  = var.aws_account_id
  region      = var.region
}

module "github_roles" {
  source = "../modules/iam-oidc"

  project                       = var.project
  account_id                    = var.aws_account_id
  region                        = var.region
  oidc_provider_arn             = local.oidc_provider_arn
  github_owner                  = var.github_owner
  github_repository             = var.github_repository
  github_oidc_immutable_subject = var.github_oidc_immutable_subject
  github_owner_id               = var.github_owner_id
  github_repository_id          = var.github_repository_id
  environments                  = var.environments
  state_bucket_arn              = aws_s3_bucket.state.arn
  ecr_repository_prefix         = "${var.project}/"
  permissions_boundaries        = { for e, m in module.boundary : e => m.boundary_arn }
  protected_name_prefixes       = var.protected_name_prefixes
}

module "ecr" {
  source = "../modules/ecr"

  repositories  = var.ecr_repositories
  push_role_arn = module.github_roles.role_arns["image-push"]
}

module "project_budget" {
  source = "../modules/budgets"

  name              = "${var.project}-project-monthly"
  monthly_limit_usd = var.project_monthly_budget_usd
  alert_emails      = [trimspace(var.alert_email)]
  project_tag_value = var.project
}
