# staging environment data for terraform/stack. Non-identifying values only: aws_account_id,
# alert_email and allowed_ingress_cidrs come from TF_VAR_* (GitHub environment "staging" variables).
environment        = "staging"
region             = "us-east-2" # PROPOSED - confirm the target region (docs/deployment-plan.md)
vpc_cidr           = "10.41.0.0/20"
log_retention_days = 14
monthly_budget_usd = 25
