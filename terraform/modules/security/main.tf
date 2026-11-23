locals {
  name = "${var.project}-${var.environment}-workload-boundary"
}

resource "aws_iam_policy" "boundary" {
  # checkov:skip=CKV_AWS_355:A permissions boundary is a ceiling; each role's own policy scopes resources.
  # checkov:skip=CKV_AWS_290:Same - write actions are bounded here and resource-scoped in role policies.
  # checkov:skip=CKV_AWS_289:Same - iam:* is explicitly DENIED below; nothing grants permissions management.
  # checkov:skip=CKV_AWS_288:Same - GetSecretValue is limited to idp/<env>/* secrets here and per service in role policies.
  name        = local.name
  description = "Permissions boundary (ceiling) for every ${var.project}-${var.environment} workload role."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WorkloadActions"
        Effect = "Allow"
        Action = [
          # ECS task execution: pull images, write logs
          "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams",
          # application telemetry
          "cloudwatch:PutMetricData", "xray:PutTraceSegments", "xray:PutTelemetryRecords",
        ]
        Resource = ["*"]
      },
      {
        Sid      = "OwnEnvironmentSecretsOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.project}/${var.environment}/*"]
      },
      {
        Sid       = "DecryptOnlyViaSecretsManager"
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = ["*"]
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } }
      },
      {
        Sid    = "NeverAllowed"
        Effect = "Deny"
        Action = [
          "iam:*", "sts:AssumeRole", "organizations:*", "account:*", "aws-portal:*", "billing:*",
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors",
        ]
        Resource = ["*"]
      },
    ]
  })
}
