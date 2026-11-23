# Offline tests for the bootstrap (mocked AWS provider, no credentials).

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
    target = data.aws_iam_openid_connect_provider.github
    values = { arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" }
  }
  # IAM policy ARNs are computed by AWS; give the mock a realistic one so module validations run.
  override_resource {
    override_during = plan
    target          = module.boundary["dev"].aws_iam_policy.boundary
    values          = { arn = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary" }
  }
  override_resource {
    override_during = plan
    target          = module.github_roles.aws_iam_role.github["image-push"]
    values          = { arn = "arn:aws:iam::111111111111:role/idp-github-image-push" }
  }
  override_resource {
    override_during = plan
    target          = aws_s3_bucket.state
    values          = { arn = "arn:aws:s3:::idp-tfstate-111111111111-us-east-2", id = "idp-tfstate-111111111111-us-east-2" }
  }
  override_resource {
    override_during = plan
    target          = aws_s3_bucket.trail
    values          = { arn = "arn:aws:s3:::idp-cloudtrail-111111111111-us-east-2", id = "idp-cloudtrail-111111111111-us-east-2" }
  }
}

variables {
  aws_account_id = "111111111111"
  alert_email    = "alerts@example.com"
}

run "shared_oidc_provider_is_looked_up_not_managed" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(data.aws_iam_openid_connect_provider.github) == 1
    error_message = "the shared GitHub OIDC provider must be looked up, never created or managed (ADR 0005)"
  }
}

run "state_bucket_is_locked_down" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "idp-tfstate-111111111111-us-east-2"
    error_message = "unexpected state bucket name"
  }
  assert {
    condition     = one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled"
    error_message = "state bucket must be versioned"
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "state bucket must block all public access"
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "state bucket must use SSE-KMS"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      st.Effect == "Deny" && try(st.Condition.Bool["aws:SecureTransport"], "") == "false"
    ])
    error_message = "state bucket must deny non-TLS access"
  }
  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled"
  }
}

run "cloudtrail_is_tamper_evident" {
  command = plan

  assert {
    condition     = aws_cloudtrail.management.enable_log_file_validation && aws_cloudtrail.management.include_global_service_events
    error_message = "trail needs log file validation and global (IAM/STS) events"
  }
  assert {
    condition     = aws_cloudtrail.management.is_multi_region_trail == false
    error_message = "owner decision: single-Region trail"
  }
  assert {
    condition = alltrue([
      for st in jsondecode(aws_s3_bucket_policy.trail.policy).Statement :
      st.Effect == "Deny" || st.Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:us-east-2:111111111111:trail/idp-management-events"
    ])
    error_message = "CloudTrail may write to the bucket only on behalf of this trail (confused-deputy protection)"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_s3_bucket_policy.trail.policy).Statement :
      st.Effect == "Deny" && contains(flatten([st.Action]), "s3:DeleteObject")
    ])
    error_message = "log files must not be deletable"
  }
  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.trail.rule).expiration).days == 365
    error_message = "default CloudTrail retention must be 365 days"
  }
}

run "modules_are_wired_with_guardrails" {
  command = plan

  assert {
    condition     = toset(keys(module.github_roles.trusted_subjects)) == toset(["dev-plan", "dev-apply", "dev-deploy", "image-push"])
    error_message = "only dev roles plus image push until staging/prod are approved"
  }
  assert {
    condition     = output.permissions_boundary_arns == { dev = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary" }
    error_message = "dev boundary must be created and passed to the apply role"
  }
}

run "refuses_wrong_account" {
  command = plan
  variables { aws_account_id = "222222222222" }
  expect_failures = [data.aws_caller_identity.current]
}

run "refuses_scp_blocked_region" {
  command = plan
  variables { region = "us-east-1" }
  expect_failures = [var.region]
}

run "rejects_short_cloudtrail_retention" {
  command = plan
  variables { cloudtrail_retention_days = 30 }
  expect_failures = [var.cloudtrail_retention_days]
}
