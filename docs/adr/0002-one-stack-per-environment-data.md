# ADR 0002: One Terraform root stack; environments are data

- **Status:** Accepted (Phase 1 proposal)
- **Date:** 2026-11-23

## Context
Three logical environments (dev, staging, prod) must have independent state but must not drift
structurally. Copy-pasted `envs/<env>/main.tf` files drift over time.

## Decision
`terraform/stack` is the single root module. `terraform/envs/<env>/` contains only
`terraform.tfvars` (non-identifying values) and `backend.hcl` (state key `envs/<env>/terraform.tfstate`,
`use_lockfile = true`). Identifying values (account ID, alert e-mail, operator /32) come from
`TF_VAR_*` set on the matching GitHub environment.

```bash
terraform -chdir=terraform/stack init -backend-config=../envs/dev/backend.hcl
terraform -chdir=terraform/stack plan -var-file=../envs/dev/terraform.tfvars -out=tfplan
```

## Consequences
- What is tested in dev is structurally identical to prod. Differences are visible in two small files.
- Environment-specific rules are expressed as validations (for example "prod requires HTTPS"),
  and they are tested offline (`terraform/stack/tests/guardrails.tftest.hcl`).
- A change to the stack affects every environment's *next* plan, which is why each environment
  has its own approval gate.
