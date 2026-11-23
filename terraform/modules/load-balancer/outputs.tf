output "alb_arn" {
  description = "Load balancer ARN."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "Load balancer ARN suffix (CloudWatch dimension)."
  value       = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "url" {
  description = "Base URL of the service."
  value       = "${local.https ? "https" : "http"}://${aws_lb.this.dns_name}"
}

output "security_group_id" {
  description = "ALB security group (tasks accept traffic only from it)."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "Target group the ECS service registers into."
  value       = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch dimension)."
  value       = aws_lb_target_group.this.arn_suffix
}
