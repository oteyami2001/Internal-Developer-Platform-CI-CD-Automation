mock_provider "aws" {}

variables {
  name              = "idp-project-monthly"
  monthly_limit_usd = 25
  alert_emails      = ["alerts@example.com"]
  project_tag_value = "idp"
}

run "project_scoped_budget_with_actual_and_forecast_alerts" {
  command = plan

  assert {
    condition     = aws_budgets_budget.this.limit_amount == "25.00" && aws_budgets_budget.this.time_unit == "MONTHLY"
    error_message = "unexpected limit"
  }
  assert {
    condition     = toset(one(aws_budgets_budget.this.cost_filter).values) == toset(["user:Project$idp"])
    error_message = "budget must be filtered on the Project=idp cost allocation tag"
  }
  assert {
    condition = toset([for n in aws_budgets_budget.this.notification : "${n.notification_type}:${n.threshold}"]) == toset([
      "ACTUAL:50", "ACTUAL:80", "ACTUAL:100", "FORECASTED:100",
    ])
    error_message = "expected 50/80/100% actual and 100% forecast alerts"
  }
}

run "rejects_oversized_limit" {
  command = plan
  variables {
    monthly_limit_usd = 1000
  }
  expect_failures = [var.monthly_limit_usd]
}
