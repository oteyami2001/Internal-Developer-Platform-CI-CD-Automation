locals {
  # The IDs are guaranteed non-null when immutable subjects are on (variable validation); the
  # fallbacks only keep static analysis (TFLint evaluating the module with defaults) from failing.
  owner_id = var.github_owner_id != null ? var.github_owner_id : ""
  repo_id  = var.github_repository_id != null ? var.github_repository_id : ""
  sub_prefix = (
    var.github_oidc_immutable_subject
    ? "repo:${var.github_owner}@${local.owner_id}/${var.github_repository}@${local.repo_id}"
    : "repo:${var.github_owner}/${var.github_repository}"
  )

  iam_arn   = "arn:aws:iam::${var.account_id}"
  ecr_repos = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${var.ecr_repository_prefix}*"

  roles = merge(
    { for e in var.environments : "${e}-plan" => { name = "${var.project}-${e}-github-plan", subject = "${local.sub_prefix}:environment:${e}-plan" } },
    { for e in var.environments : "${e}-apply" => { name = "${var.project}-${e}-github-apply", subject = "${local.sub_prefix}:environment:${e}" } },
    { for e in var.environments : "${e}-deploy" => { name = "${var.project}-${e}-github-deploy", subject = "${local.sub_prefix}:environment:${e}-deploy" } },
    { "image-push" = { name = "${var.project}-github-image-push", subject = "${local.sub_prefix}:ref:refs/heads/main" } },
  )

  # ------------------------------------------------------------------------------------------
  # Plan: metadata reads + this environment's state (read) + its lock file (write). No data
  # reads (no s3:GetObject outside the state prefix, no logs:GetLogEvents, no secret values).
  # ------------------------------------------------------------------------------------------
  plan_policies = { for e in var.environments : e => {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.state_bucket_arn]
      },
      {
        Sid      = "ReadEnvironmentState"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${var.state_bucket_arn}/envs/${e}/*"]
      },
      {
        # terraform plan takes the native S3 lock: it writes and deletes ONLY the .tflock object.
        Sid      = "StateLockFileOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${var.state_bucket_arn}/envs/${e}/*.tflock"]
      },
      {
        Sid    = "DescribeProjectServices"
        Effect = "Allow"
        Action = [
          "ec2:Describe*", "elasticloadbalancing:Describe*",
          "ecs:Describe*", "ecs:List*",
          "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy",
          "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
          "cloudwatch:Describe*", "cloudwatch:GetDashboard", "cloudwatch:ListDashboards", "cloudwatch:ListTagsForResource",
          "events:Describe*", "events:List*",
          "sns:GetTopicAttributes", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource",
          "sns:GetDataProtectionPolicy",
          "iam:GetRole", "iam:GetRolePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags", "iam:ListInstanceProfilesForRole",
          "sts:GetCallerIdentity",
        ]
        Resource = ["*"]
      },
    ]
  } }

  # ------------------------------------------------------------------------------------------
  # Apply: writes to the services terraform/stack manages, in ONE Region; IAM only on
  # <project>-<env>-* roles that carry the environment's permissions boundary; explicit denies
  # protect the other project in the shared account, the CI roles and audit/state settings.
  # ------------------------------------------------------------------------------------------
  apply_policies = { for e in var.environments : e => {
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ListStateBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = [var.state_bucket_arn]
        },
        {
          Sid      = "ReadWriteEnvironmentStateAndLock"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = ["${var.state_bucket_arn}/envs/${e}/*"]
        },
        {
          Sid    = "ProjectServicesInRegion"
          Effect = "Allow"
          Action = [
            "ec2:Describe*", "ec2:*Vpc", "ec2:*VpcAttribute", "ec2:*Subnet", "ec2:*SubnetAttribute",
            "ec2:*InternetGateway", "ec2:*RouteTable", "ec2:*Route", "ec2:*SecurityGroup*",
            "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs", "ec2:CreateTags", "ec2:DeleteTags",
            "elasticloadbalancing:*",
            "ecs:*", # includes ecs:TagResource, required because tagResourceAuthorization is on
            "logs:*", "cloudwatch:*", "events:*", "sns:*",
            "ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListTagsForResource",
          ]
          Resource  = ["*"]
          Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
        },
        {
          Sid      = "Identity"
          Effect   = "Allow"
          Action   = ["sts:GetCallerIdentity", "iam:GetRole", "iam:GetRolePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags", "iam:ListInstanceProfilesForRole"]
          Resource = ["*"]
        },
        {
          # Creating a role, or changing its permissions, REQUIRES the environment's boundary.
          Sid       = "ManageEnvironmentRolesWithBoundaryOnly"
          Effect    = "Allow"
          Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary"]
          Resource  = ["${local.iam_arn}:role/${var.project}-${e}-*"]
          Condition = { StringEquals = { "iam:PermissionsBoundary" = var.permissions_boundaries[e] } }
        },
        {
          Sid      = "ManageEnvironmentRolesMetadata"
          Effect   = "Allow"
          Action   = ["iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy"]
          Resource = ["${local.iam_arn}:role/${var.project}-${e}-*"]
        },
        {
          Sid       = "PassEnvironmentRolesToEcsAndFlowLogsOnly"
          Effect    = "Allow"
          Action    = ["iam:PassRole"]
          Resource  = ["${local.iam_arn}:role/${var.project}-${e}-*"]
          Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } }
        },
        {
          Sid       = "ServiceLinkedRoles"
          Effect    = "Allow"
          Action    = ["iam:CreateServiceLinkedRole"]
          Resource  = ["${local.iam_arn}:role/aws-service-role/*"]
          Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"] } }
        },
        {
          Sid    = "NeverAllowed"
          Effect = "Deny"
          Action = [
            "iam:DeleteRolePermissionsBoundary", "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
            "organizations:*", "account:*",
            "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors",
            "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning", "s3:PutLifecycleConfiguration",
          ]
          Resource = ["*"]
        },
        {
          Sid    = "NoChangesToCiRolesOrBoundaries"
          Effect = "Deny"
          Action = [
            "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Update*", "iam:Attach*", "iam:Detach*",
            "iam:Tag*", "iam:Untag*", "iam:Set*", "iam:PassRole",
          ]
          Resource = [
            "${local.iam_arn}:role/${var.project}-*-github-*",
            "${local.iam_arn}:role/${var.project}-github-*",
            "${local.iam_arn}:policy/${var.project}-*-workload-boundary",
          ]
        },
      ],
      # Shared account: nothing tagged with, or named after, another project may be touched.
      [for p in var.protected_name_prefixes : {
        Sid       = "ProtectTaggedResourcesOf${title(p)}"
        Effect    = "Deny"
        Action    = ["*"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:ResourceTag/Project" = p } }
      }],
      [for p in var.protected_name_prefixes : {
        Sid    = "ProtectNamedResourcesOf${title(p)}"
        Effect = "Deny"
        Action = ["*"]
        Resource = [
          "${local.iam_arn}:role/${p}-*",
          "${local.iam_arn}:policy/${p}-*",
          "arn:aws:s3:::${p}-*",
          "arn:aws:s3:::${p}-*/*",
          "arn:aws:ecr:*:${var.account_id}:repository/${p}-*",
        ]
      }],
    )
  } }

  # ------------------------------------------------------------------------------------------
  # Deploy: new task-definition revision with a digest-pinned image, then update ONE cluster's
  # services. No Terraform state, no infrastructure changes.
  # ------------------------------------------------------------------------------------------
  deploy_policies = { for e in var.environments : e => {
    Version = "2012-10-17"
    Statement = [
      {
        # RegisterTaskDefinition/Describe* do not support resource-level permissions.
        Sid       = "TaskDefinitionsInRegion"
        Effect    = "Allow"
        Action    = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        # Tag-on-create authorization is enabled in this account.
        Sid      = "TagOwnTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = ["arn:aws:ecs:${var.region}:${var.account_id}:task-definition/${var.project}-${e}-*:*"]
      },
      {
        Sid    = "UpdateServicesInEnvironmentCluster"
        Effect = "Allow"
        Action = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks", "ecs:DescribeClusters"]
        Resource = [
          "arn:aws:ecs:${var.region}:${var.account_id}:cluster/${var.project}-${e}",
          "arn:aws:ecs:${var.region}:${var.account_id}:service/${var.project}-${e}/*",
          "arn:aws:ecs:${var.region}:${var.account_id}:task/${var.project}-${e}/*",
        ]
      },
      {
        Sid       = "PassEnvironmentTaskRolesToEcsOnly"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = ["${local.iam_arn}:role/${var.project}-${e}-*"]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Sid      = "VerifyImageDigestAndScan"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
        Resource = [local.ecr_repos]
      },
    ]
  } }

  image_push_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"] # does not support resource-level permissions
        Resource = ["*"]
      },
      {
        Sid    = "PushToProjectRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
          "ecr:DescribeImages", "ecr:DescribeImageScanFindings",
        ]
        Resource = [local.ecr_repos]
      },
    ]
  }

  role_policies = merge(
    { for e in var.environments : "${e}-plan" => local.plan_policies[e] },
    { for e in var.environments : "${e}-apply" => local.apply_policies[e] },
    { for e in var.environments : "${e}-deploy" => local.deploy_policies[e] },
    { "image-push" = local.image_push_policy },
  )
}

resource "aws_iam_role" "github" {
  for_each = local.roles

  name                 = each.value.name
  description          = "GitHub Actions OIDC role (${each.key}); trusts only ${each.value.subject}"
  max_session_duration = var.max_session_duration_seconds
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsExactSubject"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = each.value.subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github" {
  # checkov:skip=CKV_AWS_290:Region-conditioned writes for services without resource-level create permissions; IAM writes are name- and boundary-scoped (see Sids).
  # checkov:skip=CKV_AWS_355:Describe/List APIs and ECS/ELB/logs create calls do not support resource-level permissions; constrained by aws:RequestedRegion.
  # checkov:skip=CKV_AWS_289:Permissions management is limited to <project>-<env>-* roles that must carry the permissions boundary.
  # checkov:skip=CKV_AWS_288:Data exfiltration check: s3:GetObject is limited to the environment's state prefix.
  # checkov:skip=CKV_AWS_286:Privilege escalation check: iam:PassRole and role creation require the boundary and a specific service.
  # checkov:skip=CKV_AWS_287:Credentials exposure check: only ecr:GetAuthorizationToken (image push), which is its purpose.
  for_each = local.role_policies

  name   = "github-${each.key}"
  role   = aws_iam_role.github[each.key].id
  policy = jsonencode(each.value)
}
