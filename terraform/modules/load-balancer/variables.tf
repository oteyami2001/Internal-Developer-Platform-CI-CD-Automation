# Internet-facing Application Load Balancer for one service (MVP: one service per environment).
#   - Without a certificate (dev demo): HTTP:80 forwards, and ingress is limited to /32 host addresses
#     (validated). With a certificate: HTTP redirects to HTTPS:443 (TLS 1.2/1.3 policy).
#   - Egress only to the VPC on the target port: the ALB cannot reach the internet.
#   - drop_invalid_header_fields, strictest desync mitigation.

variable "name_prefix" {
  description = "Resource name prefix, e.g. idp-dev (ALB/target group names must stay <= 32 chars)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be 3-16 lowercase characters."
  }
}

variable "vpc_id" {
  description = "VPC for the target group and security group."
  type        = string
}

variable "vpc_cidr" {
  description = "ALB egress is limited to this CIDR (the targets)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in at least two AZs."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires subnets in at least two Availability Zones."
  }
}

variable "certificate_arn" {
  description = "ACM certificate. null = HTTP-only demo mode (requires /32 ingress)."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "Source CIDRs allowed to reach the listener(s). Personal data: marked sensitive."
  type        = list(string)
  sensitive   = true
  validation {
    condition     = length(var.allowed_ingress_cidrs) >= 1 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrnetmask(c))])
    error_message = "Provide at least one valid IPv4 CIDR."
  }
  validation {
    condition     = var.certificate_arn != null || alltrue([for c in var.allowed_ingress_cidrs : endswith(c, "/32")])
    error_message = "Without HTTPS, ingress must be restricted to /32 host addresses."
  }
}

variable "target_port" {
  description = "Container port the target group forwards to."
  type        = number
  validation {
    condition     = var.target_port >= 1024 && var.target_port <= 65535
    error_message = "target_port must be an unprivileged port."
  }
}

variable "health_check" {
  description = "Target health check, from the validated service manifest."
  type = object({
    path                = string
    interval_seconds    = number
    healthy_threshold   = number
    unhealthy_threshold = number
  })
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
