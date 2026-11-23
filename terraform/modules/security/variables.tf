# tflint-ignore-file: terraform_unused_declarations # SKELETON: inputs are the contract; resources arrive in Phase 3/4.
# Remove this line when the configuration gets resources (enforced by tests/platform/test_repo_hygiene.py).

# MODULE CONTRACT (Phase 1 skeleton - resources are implemented in Phase 3/4)
#
# Planned resources:
#   aws_iam_policy  workload permissions boundary (ceiling for every role the platform creates:
#                   no IAM writes, no Organizations/account/billing, no CloudTrail tampering)
#   aws_iam_role    ECS task execution role per service (pull from its ECR repo, write its log group,
#                   read ONLY secrets under idp/<env>/<service>/*)
#   aws_iam_role    ECS task role per service (empty by default - the sample app needs no AWS access)
# Service manifests have no IAM fields, so developers cannot widen these roles.

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "services" {
  description = "Service names from the validated catalog."
  type        = list(string)
}

variable "ecr_repository_arns" {
  description = "Service name -> ECR repository ARN."
  type        = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
