# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 4)
#
# Planned resources:
#   aws_lb (application, internet-facing, drop_invalid_header_fields = true)
#   aws_security_group (ingress only from allowed_ingress_cidrs on 80/443; egress only to the VPC)
#   aws_lb_target_group (ip targets, health check on the manifest path, short deregistration delay)
#   aws_lb_listener HTTP:80 -> forward (dev /32 demo) OR redirect to HTTPS:443 when a certificate is set
#   aws_lb_listener HTTPS:443 (ELBSecurityPolicy-TLS13-1-2-2021-06) when certificate_arn is set

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "ALB egress is limited to the VPC (targets only)."
  type        = string
}

variable "public_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires subnets in at least two Availability Zones."
  }
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "allowed_ingress_cidrs" {
  type = list(string)
  validation {
    condition     = var.certificate_arn != null || alltrue([for c in var.allowed_ingress_cidrs : endswith(c, "/32")])
    error_message = "Without HTTPS, ingress must be restricted to /32 host addresses."
  }
}

variable "target_port" {
  type = number
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "deregistration_delay_seconds" {
  description = "Connection draining. Kept short (but above the app's in-flight request time) so deploys are fast."
  type        = number
  default     = 30
  validation {
    condition     = var.deregistration_delay_seconds >= 5 && var.deregistration_delay_seconds <= 120
    error_message = "deregistration_delay_seconds must be 5-120."
  }
}

variable "enable_deletion_protection" {
  description = "true for prod; false for dev so approved cleanup can remove it."
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "Optional S3 bucket for ALB access logs (recommended for prod)."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
