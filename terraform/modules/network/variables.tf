# VPC for one environment (dev MVP topology, docs/architecture.md §4.1):
#   - public subnets (ALB, and dev-mode Fargate tasks with public IPs: no NAT Gateway, exception SE-1)
#   - private subnets defined for the production reference, with NO default route (no NAT cost)
#   - default security group stripped of all rules; subnets never auto-assign public IPs
#   - VPC flow logs (REJECT by default) to CloudWatch Logs through a boundary-carrying IAM role

variable "name_prefix" {
  description = "Resource name prefix, e.g. idp-dev (IAM role names must match the apply role's idp-<env>-* scope)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase characters."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR (/16 to /24). Subnets are /4 splits: public = first az_count, private = from the 9th."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /24."
  }
}

variable "az_count" {
  description = "Availability Zones to span (an ALB needs at least 2)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "create_private_subnets" {
  description = "Create private subnets (no default route in the MVP; the production reference adds egress)."
  type        = bool
  default     = true
}

variable "flow_logs_traffic_type" {
  description = "VPC flow log filter. REJECT keeps ingestion cost minimal while recording blocked traffic."
  type        = string
  default     = "REJECT"
  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "log_retention_days" {
  description = "Flow log retention in days."
  type        = number
}

variable "permissions_boundary_arn" {
  description = "Boundary every role in this environment must carry (the apply role cannot create roles without it)."
  type        = string
}
