# Offline tests: the trust and permission claims in docs/security-model.md, as assertions.

mock_provider "aws" {}

variables {
  project                       = "idp"
  account_id                    = "111111111111"
  region                        = "us-east-2"
  oidc_provider_arn             = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  github_owner                  = "oteyami2001"
  github_repository             = "Internal-Developer-Platform-CI-CD-Automation"
  github_oidc_immutable_subject = true
  github_owner_id               = "157901928"
  github_repository_id          = "1465573837"
  environments                  = ["dev"]
  state_bucket_arn              = "arn:aws:s3:::idp-tfstate-111111111111-us-east-2"
  ecr_repository_prefix         = "idp/"
  permissions_boundaries        = { dev = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary" }
  protected_name_prefixes       = ["aiops"]
}

run "roles_and_exact_subjects" {
  command = plan

  assert {
    condition     = toset(keys(aws_iam_role.github)) == toset(["dev-plan", "dev-apply", "dev-deploy", "image-push"])
    error_message = "unexpected role set"
  }
  assert {
    condition     = aws_iam_role.github["dev-apply"].name == "idp-dev-github-apply" && aws_iam_role.github["image-push"].name == "idp-github-image-push"
    error_message = "unexpected role names"
  }
  assert {
    condition = output.trusted_subjects == {
      "dev-plan"   = "repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837:environment:dev-plan"
      "dev-apply"  = "repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837:environment:dev"
      "dev-deploy" = "repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837:environment:dev-deploy"
      "image-push" = "repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837:ref:refs/heads/main"
    }
    error_message = "trusted subjects are not the exact expected immutable subjects"
  }
}

run "trust_policies_are_exact_and_audience_bound" {
  command = plan

  assert {
    condition = alltrue([for k, r in aws_iam_role.github : alltrue([
      for st in jsondecode(r.assume_role_policy).Statement :
      st.Action == "sts:AssumeRoleWithWebIdentity"
      && st.Principal.Federated == var.oidc_provider_arn
      && keys(st.Condition) == ["StringEquals"]
      && st.Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
      && length(regexall("[*?]", st.Condition.StringEquals["token.actions.githubusercontent.com:sub"])) == 0
    ])])
    error_message = "every trust policy must use StringEquals on aud and an exact, wildcard-free sub"
  }
  assert {
    condition     = alltrue([for k, s in output.trusted_subjects : !strcontains(s, "pull_request")])
    error_message = "no role may trust pull requests (ADR 0003)"
  }
}

run "plan_role_is_read_only" {
  command = plan

  assert {
    # Every Allow outside the lock-file statement is a read-style action or s3:ListBucket/GetObject.
    condition = alltrue([
      for st in jsondecode(aws_iam_role_policy.github["dev-plan"].policy).Statement :
      st.Sid == "StateLockFileOnly" || alltrue([
        for a in st.Action : length(regexall("^[a-z0-9-]+:(Describe|List|Get)", a)) > 0
      ])
    ])
    error_message = "plan role may only Describe/List/Get (besides the lock file)"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["dev-plan"].policy).Statement : st.Resource if st.Sid == "StateLockFileOnly"
    ]) == ["arn:aws:s3:::idp-tfstate-111111111111-us-east-2/envs/dev/*.tflock"]
    error_message = "plan role may write only the environment's .tflock object"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["dev-plan"].policy).Statement : st.Resource if st.Sid == "ReadEnvironmentState"
    ]) == ["arn:aws:s3:::idp-tfstate-111111111111-us-east-2/envs/dev/*"]
    error_message = "plan role may read only its environment's state prefix"
  }
}

run "apply_role_guardrails" {
  command = plan

  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement : st.Condition if st.Sid == "ProjectServicesInRegion"
    ]) == { StringEquals = { "aws:RequestedRegion" = "us-east-2" } }
    error_message = "service writes must be locked to the project Region"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement : st.Condition if st.Sid == "ManageEnvironmentRolesWithBoundaryOnly"
    ]) == { StringEquals = { "iam:PermissionsBoundary" = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary" } }
    error_message = "role creation must require the permissions boundary"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement :
      st.Effect == "Deny" && st.Action == ["*"] && try(st.Condition.StringEquals["aws:ResourceTag/Project"], "") == "aiops"
    ])
    error_message = "apply role must be denied everything on resources tagged Project=aiops (ADR 0005)"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement :
      st.Effect == "Deny" && contains(st.Resource, "arn:aws:iam::111111111111:role/aiops-*") && contains(st.Resource, "arn:aws:s3:::aiops-*")
    ])
    error_message = "apply role must be denied aiops-* IAM roles and S3 buckets"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement :
      st.Effect == "Deny" && contains(st.Action, "cloudtrail:StopLogging") && contains(st.Action, "iam:CreateAccessKey")
    ])
    error_message = "apply role must be denied audit tampering and long-lived credentials"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_role_policy.github["dev-apply"].policy).Statement :
      st.Effect == "Deny" && contains(st.Resource, "arn:aws:iam::111111111111:role/idp-*-github-*")
    ])
    error_message = "apply role must not be able to modify the CI roles"
  }
  assert {
    condition     = length(aws_iam_role_policy.github["dev-apply"].policy) < 10240
    error_message = "inline role policy exceeds the 10,240-character IAM limit"
  }
}

run "deploy_and_push_roles_are_narrow" {
  command = plan

  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["dev-deploy"].policy).Statement : st.Resource if st.Sid == "UpdateServicesInEnvironmentCluster"
    ]) == ["arn:aws:ecs:us-east-2:111111111111:cluster/idp-dev", "arn:aws:ecs:us-east-2:111111111111:service/idp-dev/*", "arn:aws:ecs:us-east-2:111111111111:task/idp-dev/*"]
    error_message = "deploy role must be limited to the environment's cluster"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.github["dev-deploy"].policy, "s3:")
    error_message = "deploy role must have no access to Terraform state"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_role_policy.github["image-push"].policy).Statement : st.Resource if st.Sid == "PushToProjectRepositories"
    ]) == ["arn:aws:ecr:us-east-2:111111111111:repository/idp/*"]
    error_message = "image push must be limited to idp/* repositories"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.github["image-push"].policy, "BatchDeleteImage")
    error_message = "image push role must not delete images"
  }
}

run "mutable_subjects_when_not_customized" {
  command = plan
  variables {
    github_oidc_immutable_subject = false
  }
  assert {
    condition     = output.trusted_subjects["dev-apply"] == "repo:oteyami2001/Internal-Developer-Platform-CI-CD-Automation:environment:dev"
    error_message = "plain subject format expected"
  }
}

run "immutable_subjects_require_ids" {
  command = plan
  variables {
    github_repository_id = null
  }
  expect_failures = [var.github_repository_id]
}

run "every_environment_needs_a_boundary" {
  command = plan
  variables {
    environments = ["dev", "prod"]
  }
  expect_failures = [var.permissions_boundaries]
}
