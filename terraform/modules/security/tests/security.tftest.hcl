mock_provider "aws" {}

variables {
  project     = "idp"
  environment = "dev"
  account_id  = "111111111111"
  region      = "us-east-2"
}

run "boundary_is_a_tight_ceiling" {
  command = plan

  assert {
    condition     = aws_iam_policy.boundary.name == "idp-dev-workload-boundary"
    error_message = "boundary name must match the apply role's protected pattern idp-*-workload-boundary"
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_policy.boundary.policy).Statement :
      st.Effect == "Deny" && contains(st.Action, "iam:*") && contains(st.Action, "organizations:*") && contains(st.Action, "cloudtrail:StopLogging")
    ])
    error_message = "boundary must deny IAM, Organizations and CloudTrail tampering"
  }
  assert {
    condition = alltrue([
      for st in jsondecode(aws_iam_policy.boundary.policy).Statement :
      st.Effect == "Deny" || alltrue([for a in st.Action : !startswith(a, "iam:") && a != "*" && !endswith(a, ":*")])
    ])
    error_message = "boundary must not allow IAM or service-wide wildcards"
  }
  assert {
    condition = one([
      for st in jsondecode(aws_iam_policy.boundary.policy).Statement : st.Resource if st.Sid == "OwnEnvironmentSecretsOnly"
    ]) == ["arn:aws:secretsmanager:us-east-2:111111111111:secret:idp/dev/*"]
    error_message = "secrets must be limited to the environment namespace"
  }
}
