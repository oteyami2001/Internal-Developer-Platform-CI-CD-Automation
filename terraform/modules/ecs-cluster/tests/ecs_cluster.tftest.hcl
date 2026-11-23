mock_provider "aws" {}

variables {
  name_prefix = "idp-dev"
}

run "fargate_cluster_named_for_the_deploy_role_scope" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.this.name == "idp-dev"
    error_message = "cluster name must match the deploy role's cluster/idp-dev scope"
  }
  assert {
    condition     = one(aws_ecs_cluster.this.setting).value == "disabled"
    error_message = "Container Insights must default to off in dev (cost)"
  }
  assert {
    condition     = aws_ecs_cluster_capacity_providers.this.capacity_providers == toset(["FARGATE"])
    error_message = "on-demand Fargate only unless Spot is chosen"
  }
}

run "rejects_unknown_insights_mode" {
  command = plan
  variables { container_insights = "maybe" }
  expect_failures = [var.container_insights]
}
