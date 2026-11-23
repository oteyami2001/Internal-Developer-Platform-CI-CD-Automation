mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-2a", "us-east-2b", "us-east-2c"] }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
}

variables {
  name_prefix              = "idp-dev"
  vpc_cidr                 = "10.40.0.0/20"
  log_retention_days       = 7
  permissions_boundary_arn = "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary"
}

run "two_az_layout_without_nat" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "expected 2 public and 2 private subnets"
  }
  assert {
    condition     = toset([for s in aws_subnet.public : s.cidr_block]) == toset(["10.40.0.0/24", "10.40.1.0/24"])
    error_message = "unexpected public subnet CIDRs"
  }
  assert {
    condition     = alltrue([for s in concat(values(aws_subnet.public), values(aws_subnet.private)) : s.map_public_ip_on_launch == false])
    error_message = "subnets must never auto-assign public IPs"
  }
  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0" && length(aws_route_table.private) == 1
    error_message = "public subnets route via the IGW; the private route table exists"
  }
}

run "default_security_group_is_locked" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "the default security group must have no rules"
  }
}

run "flow_logs_with_bounded_role" {
  command = plan

  assert {
    condition     = aws_flow_log.this.traffic_type == "REJECT" && aws_cloudwatch_log_group.flow_logs.retention_in_days == 7
    error_message = "flow logs must record REJECTs with bounded retention"
  }
  assert {
    condition     = aws_iam_role.flow_logs.name == "idp-dev-vpc-flow-logs" && aws_iam_role.flow_logs.permissions_boundary == "arn:aws:iam::111111111111:policy/idp-dev-workload-boundary"
    error_message = "flow logs role must be in the environment's name scope and carry the boundary"
  }
  assert {
    condition     = jsondecode(aws_iam_role.flow_logs.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    error_message = "flow logs trust must be pinned to this account (confused deputy)"
  }
}

run "rejects_single_az" {
  command = plan
  variables { az_count = 1 }
  expect_failures = [var.az_count]
}
