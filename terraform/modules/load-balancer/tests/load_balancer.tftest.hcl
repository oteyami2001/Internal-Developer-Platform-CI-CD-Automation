mock_provider "aws" {}

variables {
  name_prefix           = "idp-dev"
  vpc_id                = "vpc-12345678"
  vpc_cidr              = "10.40.0.0/20"
  public_subnet_ids     = ["subnet-aaaa", "subnet-bbbb"]
  allowed_ingress_cidrs = ["203.0.113.10/32"]
  target_port           = 8080
  health_check          = { path = "/health", interval_seconds = 30, healthy_threshold = 2, unhealthy_threshold = 3 }
}

run "demo_mode_http_from_one_host_only" {
  command = plan

  assert {
    condition     = aws_lb.this.internal == false && aws_lb.this.drop_invalid_header_fields && aws_lb.this.desync_mitigation_mode == "strictest"
    error_message = "ALB must drop invalid headers and use strictest desync mitigation"
  }
  assert {
    condition     = length(aws_security_group.alb.ingress) == 1 && one(aws_security_group.alb.ingress).from_port == 80
    error_message = "demo mode exposes only port 80"
  }
  assert {
    condition     = nonsensitive(one(aws_security_group.alb.ingress).cidr_blocks) == tolist(["203.0.113.10/32"])
    error_message = "ingress must be exactly the allowed /32"
  }
  assert {
    condition     = one(aws_security_group.alb.egress).cidr_blocks == tolist(["10.40.0.0/20"]) && one(aws_security_group.alb.egress).from_port == 8080
    error_message = "ALB egress must be limited to the VPC on the target port"
  }
  assert {
    condition     = one(aws_lb_listener.http.default_action).type == "forward" && length(aws_lb_listener.https) == 0
    error_message = "demo mode forwards HTTP and has no HTTPS listener"
  }
  assert {
    condition     = aws_lb_target_group.this.target_type == "ip" && one(aws_lb_target_group.this.health_check).path == "/health"
    error_message = "Fargate needs ip targets; health check comes from the manifest"
  }
}

run "https_mode_redirects_and_uses_tls12_plus" {
  command = plan
  variables {
    certificate_arn       = "arn:aws:acm:us-east-2:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = one(aws_lb_listener.http.default_action).type == "redirect"
    error_message = "with a certificate, HTTP must redirect to HTTPS"
  }
  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "HTTPS listener must use the TLS 1.3/1.2 policy"
  }
}

run "rejects_open_http" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_ingress_cidrs]
}
