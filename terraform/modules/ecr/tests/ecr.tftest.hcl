mock_provider "aws" {}

variables {
  repositories  = { "idp/sample-api" = {} }
  push_role_arn = "arn:aws:iam::111111111111:role/idp-github-image-push"
}

run "repositories_are_immutable_scanned_and_encrypted" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this["idp/sample-api"].image_tag_mutability == "IMMUTABLE"
    error_message = "tags must be immutable"
  }
  assert {
    condition     = aws_ecr_repository.this["idp/sample-api"].image_scanning_configuration[0].scan_on_push
    error_message = "scan on push must be on"
  }
  assert {
    condition     = aws_ecr_repository.this["idp/sample-api"].encryption_configuration[0].encryption_type == "KMS"
    error_message = "repositories must be KMS-encrypted"
  }
  assert {
    condition     = aws_ecr_repository.this["idp/sample-api"].force_delete == false
    error_message = "repositories with images must not be force-deleted"
  }
}

run "only_the_pipeline_can_push" {
  command = plan

  assert {
    condition = jsondecode(aws_ecr_repository_policy.this["idp/sample-api"].policy).Statement == [{
      Sid       = "OnlyThePipelinePushes"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = "arn:aws:iam::111111111111:role/idp-github-image-push" } }
    }]
    error_message = "repository policy must deny pushes from everyone except the image-push role"
  }
}

run "lifecycle_keeps_rollback_images" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this["idp/sample-api"].policy).rules[1].selection.countNumber == 20
    error_message = "default retention must keep 20 images"
  }
}

run "rejects_bad_repository_names" {
  command = plan
  variables { repositories = { "Sample_API" = {} } }
  expect_failures = [var.repositories]
}

run "rejects_too_little_rollback_history" {
  command = plan
  variables { repositories = { "idp/sample-api" = { max_images = 1 } } }
  expect_failures = [var.repositories]
}
