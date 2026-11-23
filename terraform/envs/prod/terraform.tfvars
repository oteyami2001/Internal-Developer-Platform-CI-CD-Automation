# prod environment data for terraform/stack. Non-identifying values only: aws_account_id,
# alert_email and allowed_ingress_cidrs come from TF_VAR_* (GitHub environment "prod" variables).
environment        = "prod"
region             = "us-east-2" # shared AIOps account; us-east-1 is denied by SCP (ADR 0005)
vpc_cidr           = "10.42.0.0/20"
log_retention_days = 30
monthly_budget_usd = 60

# prod: HTTPS is mandatory (variable validation rejects prod without certificate_arn).
# certificate_arn = "arn:aws:acm:us-east-2:<ACCOUNT_ID>:certificate/<ID>"
