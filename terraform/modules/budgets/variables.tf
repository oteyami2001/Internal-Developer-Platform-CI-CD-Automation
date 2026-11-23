# Project-scoped monthly cost budget (ACTUAL thresholds + a FORECASTED alert).
#
# A budget only NOTIFIES; it never stops resources. The cost filter uses the `Project` cost
# allocation tag. In an AWS Organizations member account, the tag must be ACTIVATED by the
# management (payer) account (Billing -> Cost allocation tags); until then this budget reads $0.
# The account-wide budget (aiops-account-monthly) remains the backstop meanwhile (ADR 0005).

variable "name" {
  description = "Budget name."
  type        = string
}

variable "monthly_limit_usd" {
  description = "Monthly limit in USD."
  type        = number
  validation {
    condition     = var.monthly_limit_usd >= 1 && var.monthly_limit_usd <= 200
    error_message = "monthly_limit_usd must be 1-200."
  }
}

variable "alert_emails" {
  description = "Recipients of budget alerts."
  type        = list(string)
  sensitive   = true # personal data: keep it out of plan output and CI logs
  validation {
    condition     = length(var.alert_emails) >= 1 && length(var.alert_emails) <= 10
    error_message = "Provide 1-10 alert e-mail addresses."
  }
}

variable "actual_thresholds_percent" {
  description = "Alert when ACTUAL spend crosses these percentages."
  type        = list(number)
  default     = [50, 80, 100]
}

variable "forecast_threshold_percent" {
  description = "Alert when FORECASTED spend crosses this percentage."
  type        = number
  default     = 100
}

variable "project_tag_value" {
  description = "Only costs tagged Project=<value> count toward this budget."
  type        = string
}
