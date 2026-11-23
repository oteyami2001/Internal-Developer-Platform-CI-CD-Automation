# tflint-ignore-file: terraform_unused_declarations # SKELETON: inputs are the contract; resources arrive in Phase 3/4.
# Remove this line when the configuration gets resources (enforced by tests/platform/test_repo_hygiene.py).

# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 3)
#
# Planned resources:
#   aws_budgets_budget (monthly COST budget filtered on the Project tag, ACTUAL + FORECASTED alerts)
# A budget only NOTIFIES. It never stops resources; cleanup.yml is the cost-control action.

variable "name_prefix" {
  type = string
}

variable "monthly_limit_usd" {
  type = number
  validation {
    condition     = var.monthly_limit_usd >= 1 && var.monthly_limit_usd <= 200
    error_message = "monthly_limit_usd must be 1-200."
  }
}

variable "alert_emails" {
  type = list(string)
  validation {
    condition     = length(var.alert_emails) >= 1 && length(var.alert_emails) <= 10
    error_message = "Provide 1-10 alert e-mail addresses."
  }
}

variable "actual_thresholds_percent" {
  type    = list(number)
  default = [50, 80, 100]
}

variable "forecast_threshold_percent" {
  type    = number
  default = 100
}

variable "project_tag_value" {
  description = "Cost filter: only resources tagged Project=<value> count toward this budget (requires the tag to be activated as a cost-allocation tag)."
  type        = string
}
