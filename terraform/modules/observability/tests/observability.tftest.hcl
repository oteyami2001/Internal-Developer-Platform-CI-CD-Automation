mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_resource {
    target          = aws_sns_topic.alerts
    override_during = plan
    values          = { arn = "arn:aws:sns:us-east-2:111111111111:idp-dev-alerts" }
  }
  override_resource {
    target          = aws_cloudwatch_log_group.deployment_events
    override_during = plan
    values          = { arn = "arn:aws:logs:us-east-2:111111111111:log-group:/aws/events/idp-dev/ecs-deployments" }
  }
}

variables {
  name_prefix             = "idp-dev"
  alert_email             = "alerts@example.com"
  cluster_name            = "idp-dev"
  alb_arn_suffix          = "app/idp-dev/0123456789abcdef"
  target_group_arn_suffix = "targetgroup/idp-dev-tg/0123456789abcdef"
  log_retention_days      = 7
}

run "infrastructure_only_has_alb_alarms" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.no_healthy_targets) == 0 && length(aws_cloudwatch_metric_alarm.service_cpu) == 0
    error_message = "service alarms must not exist (and alarm forever) before a service is deployed"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_5xx.alarm_actions == toset([aws_sns_topic.alerts.arn])
    error_message = "alarms must notify the alert topic"
  }
}

run "service_alarms_when_service_exists" {
  command = plan
  variables {
    service_name = "sample-api"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.no_healthy_targets) == 1 && aws_cloudwatch_metric_alarm.no_healthy_targets[0].treat_missing_data == "breaching"
    error_message = "a running service must alarm when it has no healthy target (missing data = down)"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.service_cpu[0].dimensions == tomap({ ClusterName = "idp-dev", ServiceName = "sample-api" })
    error_message = "CPU alarm must watch the service"
  }
}

run "deployment_events_are_recorded" {
  command = plan

  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.ecs_deployments.event_pattern)["detail-type"]) == toset(["ECS Deployment State Change", "ECS Service Action"])
    error_message = "deployment and service-action events must be captured"
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.ecs_deployments.event_pattern).resources[0].prefix == "arn:aws:ecs:us-east-2:111111111111:service/idp-dev/"
    error_message = "only this cluster's services"
  }
  assert {
    condition     = jsondecode(aws_sns_topic_policy.alerts.policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    error_message = "only this account's alarms/events may publish (confused deputy)"
  }
}
