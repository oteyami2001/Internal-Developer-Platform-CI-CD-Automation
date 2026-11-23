locals {
  https = var.certificate_arn != null
}

resource "aws_security_group" "alb" {
  # checkov:skip=CKV_AWS_260:Port 80 is open only to var.allowed_ingress_cidrs, which validation limits to /32 hosts without HTTPS.
  name        = "${var.name_prefix}-alb"
  description = "ALB: listener ingress from allowed CIDRs only; egress to the VPC targets only"
  vpc_id      = var.vpc_id

  ingress {
    description = local.https ? "HTTP (redirected to HTTPS)" : "HTTP demo listener (/32 only)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  dynamic "ingress" {
    for_each = local.https ? [1] : []
    content {
      description = "HTTPS listener"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  egress {
    description = "To targets in the VPC on the container port only"
    from_port   = var.target_port
    to_port     = var.target_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.name_prefix}-alb" }
}

#trivy:ignore:AVD-AWS-0053 Internet-facing by design (demo endpoint); ingress is restricted by the security group to /32 hosts or HTTPS.
resource "aws_lb" "this" {
  # checkov:skip=CKV2_AWS_20:HTTP->HTTPS redirect is configured whenever a certificate exists; demo mode has none (SE-2, /32 ingress).
  # checkov:skip=CKV2_AWS_28:No WAF for the dev demo (cost); ingress is limited to /32 hosts. WAF is in the production reference.
  # checkov:skip=CKV_AWS_91:Access logs need an S3 bucket the apply role may not configure (bucket policies are denied); production reference.
  # checkov:skip=CKV_AWS_150:Deletion protection is off in dev so the approved cleanup workflow can remove it; var.enable_deletion_protection for prod.
  name                       = var.name_prefix
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  idle_timeout               = 60
  enable_deletion_protection = var.enable_deletion_protection
}

resource "aws_lb_target_group" "this" {
  # checkov:skip=CKV_AWS_378:TLS terminates at the ALB; ALB-to-task traffic stays inside the VPC and the task SG accepts only the ALB SG.
  name                 = "${var.name_prefix}-tg"
  target_type          = "ip"
  port                 = var.target_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    path                = var.health_check.path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check.interval_seconds
    timeout             = 5
    healthy_threshold   = var.health_check.healthy_threshold
    unhealthy_threshold = var.health_check.unhealthy_threshold
  }
}

#trivy:ignore:AVD-AWS-0054 HTTP is used only in the documented demo mode (no certificate, /32 ingress, SE-2); with a certificate it redirects to HTTPS.
resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_2:HTTP forward only in demo mode without a certificate (SE-2, /32 ingress); otherwise a redirect to HTTPS.
  # checkov:skip=CKV_AWS_103:TLS policy applies to the HTTPS listener below; this listener is HTTP by design.
  # checkov:skip=CKV2_AWS_20:Redirects to HTTPS whenever a certificate exists; demo mode has none (SE-2).
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }

  dynamic "default_action" {
    for_each = local.https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
