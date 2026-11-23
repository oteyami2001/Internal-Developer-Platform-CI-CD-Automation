#trivy:ignore:AVD-AWS-0033 KMS with the AWS managed aws/ecr key; a customer managed key adds $1/month for no extra control needed here.
resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false # images are evidence; deleting a repository with images must be deliberate

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.encryption_type
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest ${var.repositories[each.key].max_images} images for rollback"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.repositories[each.key].max_images }
        action       = { type = "expire" }
      },
    ]
  })
}

resource "aws_ecr_repository_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyThePipelinePushes"
      Effect    = "Deny"
      Principal = "*"
      Action = [
        "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
      ]
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = var.push_role_arn } }
    }]
  })
}
