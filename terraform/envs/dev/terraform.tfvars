# dev environment data for terraform/stack. Non-identifying values only: aws_account_id,
# alert_email and allowed_ingress_cidrs come from TF_VAR_* (GitHub environment "dev" variables).
environment        = "dev"
region             = "us-east-2" # shared AIOps account; us-east-1 is denied by SCP (ADR 0005)
vpc_cidr           = "10.40.0.0/20"
log_retention_days = 7
