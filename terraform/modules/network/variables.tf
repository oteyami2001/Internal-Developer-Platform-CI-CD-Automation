# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 4)
#
# Planned resources:
#   aws_vpc (DNS support/hostnames), aws_internet_gateway
#   public subnets  x az_count (ALB; dev-mode Fargate tasks with public IPs)
#   private subnets x az_count (defined, route table without a default route: NO NAT Gateway in the
#                               MVP; the production reference adds NAT or VPC endpoints)
#   aws_default_security_group with all rules removed (CKV2_AWS_12)
#   aws_flow_log -> CloudWatch Logs (REJECT traffic only, short retention, to bound cost)

variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "create_private_subnets" {
  type    = bool
  default = true
}

variable "flow_logs_traffic_type" {
  type    = string
  default = "REJECT"
  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "log_retention_days" {
  type = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
