data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:Only the first var.az_count names (sorted) are used; a newly added AZ sorts after the existing letters, so the selection cannot silently change.
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  public_subnets  = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 4, i) }
  private_subnets = var.create_private_subnets ? { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 4, i + 8) } : {}
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name_prefix }
}

# No rules at all: every resource uses its own, explicit security group (CKV2_AWS_12).
resource "aws_default_security_group" "this" {
  vpc_id  = aws_vpc.this.id
  ingress = [] # explicitly empty: removes the default allow-all-from-self rule
  egress  = [] # explicitly empty: removes the default allow-all egress rule
  tags    = { Name = "${var.name_prefix}-default-locked" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name_prefix }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value
  # Never auto-assign: a task gets a public IP only when its ECS service explicitly asks (SE-1).
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-public-${each.key}", Tier = "public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-private-${each.key}", Tier = "private" }
}

# Private route table WITHOUT a default route: nothing in a private subnet can reach the internet
# until the production reference adds VPC endpoints or a NAT Gateway.
resource "aws_route_table" "private" {
  count  = var.create_private_subnets ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[0].id
}

# ---------------------------------------------------------------------------------------------
# VPC flow logs
# ---------------------------------------------------------------------------------------------
#trivy:ignore:AVD-AWS-0017 AWS-owned encryption at rest; a customer managed KMS key adds $1/month.
resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_158:Encrypted at rest with the CloudWatch Logs service key; a CMK adds $1/month (cost model).
  # checkov:skip=CKV_AWS_338:Retention is bounded by var.log_retention_days (dev: 7 days) to control cost.
  name              = "/${replace(var.name_prefix, "-", "/")}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "flow_logs" {
  name                 = "${var.name_prefix}-vpc-flow-logs"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_logs_traffic_type
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 600
}
