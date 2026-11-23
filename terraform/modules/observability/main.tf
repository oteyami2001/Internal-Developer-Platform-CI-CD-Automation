data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  service_alarms = var.service_name != null
  alb_dims       = { LoadBalancer = var.alb_arn_suffix }
  tg_dims        = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
}

# ---------------------------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------------------------
#trivy:ignore:AVD-AWS-0095 CloudWatch alarms and EventBridge cannot publish to a topic encrypted with the AWS managed aws/sns key; a CMK adds $1/month. Messages carry no secrets.
resource "aws_sns_topic" "alerts" {
  # checkov:skip=CKV_AWS_26:CloudWatch and EventBridge cannot publish to a topic encrypted with the AWS managed aws/sns key; a CMK adds $1/month. Alerts carry no secret data.
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AlarmsAndEventsFromThisAccountOnly"
      Effect    = "Allow"
      Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx"
  alarm_description   = "Load balancer returned 5xx (no healthy target, or ALB error)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = local.alb_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.http_5xx_per_5min
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name_prefix}-target-5xx"
  alarm_description   = "The application returned 5xx responses."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.tg_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.http_5xx_per_5min
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95"
  alarm_description   = "p95 target response time is above the threshold."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.tg_dims
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_thresholds.p95_latency_ms / 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.name_prefix}-unhealthy-targets"
  alarm_description   = "At least one target is failing the load balancer health check."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.tg_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  count = local.service_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-no-healthy-targets"
  alarm_description   = "The service has no healthy target: it is down."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dims
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "service_cpu" {
  count = local.service_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-${var.service_name}-cpu"
  alarm_description   = "Service CPU utilisation is high."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_thresholds.cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "service_memory" {
  count = local.service_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-${var.service_name}-memory"
  alarm_description   = "Service memory utilisation is high."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_thresholds.memory_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------------------------
# ECS deployment and service events -> e-mail + a durable log (deployment history)
# ---------------------------------------------------------------------------------------------
#trivy:ignore:AVD-AWS-0017 AWS-owned encryption at rest; a customer managed KMS key adds $1/month.
resource "aws_cloudwatch_log_group" "deployment_events" {
  # checkov:skip=CKV_AWS_158:Encrypted at rest with the CloudWatch Logs service key; a CMK adds $1/month (cost model).
  # checkov:skip=CKV_AWS_338:Retention is bounded by var.log_retention_days to control cost.
  name              = "/aws/events/${var.name_prefix}/ecs-deployments"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_resource_policy" "deployment_events" {
  policy_name = "${var.name_prefix}-ecs-deployment-events"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBridgeWritesDeploymentEvents"
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.deployment_events.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_event_rule" "ecs_deployments" {
  name        = "${var.name_prefix}-ecs-deployments"
  description = "ECS deployment state changes and service actions in ${var.cluster_name}"
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Deployment State Change", "ECS Service Action"]
    resources   = [{ prefix = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:service/${var.cluster_name}/" }]
  })
}

resource "aws_cloudwatch_event_target" "deployments_to_sns" {
  rule = aws_cloudwatch_event_rule.ecs_deployments.name
  arn  = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_target" "deployments_to_logs" {
  rule = aws_cloudwatch_event_rule.ecs_deployments.name
  arn  = aws_cloudwatch_log_group.deployment_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.deployment_events]
}

# ---------------------------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name_prefix
  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type = "metric", x = 0, y = 0, width = 12, height = 6
          properties = {
            title  = "Requests and errors"
            region = data.aws_region.current.region
            stat   = "Sum"
            period = 60
            metrics = [
              ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
              ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
              ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix],
            ]
          }
        },
        {
          type = "metric", x = 12, y = 0, width = 12, height = 6
          properties = {
            title  = "Latency (p50 / p95) and target health"
            region = data.aws_region.current.region
            period = 60
            metrics = [
              ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "p50" }],
              ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "p95" }],
              ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Minimum", yAxis = "right" }],
            ]
          }
        },
      ],
      local.service_alarms ? [{
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS ${var.service_name}: CPU and memory"
          region = data.aws_region.current.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
          ]
        }
      }] : [],
      [{
        type = "log", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS deployment events"
          region = data.aws_region.current.region
          query  = "SOURCE '${aws_cloudwatch_log_group.deployment_events.name}' | fields @timestamp, detail.eventName, detail.deploymentId, detail.reason | sort @timestamp desc | limit 20"
          view   = "table"
        }
      }],
    )
  })
}
