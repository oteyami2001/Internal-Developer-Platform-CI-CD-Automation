# ADR 0005: Deploy into the AIOps project's AWS account, keeping all of its resources

- **Status:** Accepted (owner decision, 2026-11-23: "we keep everything from the last project account")
- **Date:** 2026-11-23

## Context

The AIOps project ([oteyami2001/AWS-Cloud-Operations-AI-Automation](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation))
destroyed its dev environment on 2026-11-22 (81 resources) and **intentionally kept its bootstrap**
(about $0.01/month):

| Retained AIOps resource | Relevance to this project |
|---|---|
| GitHub OIDC provider `token.actions.githubusercontent.com` | One per account: **shared**, looked up, never managed here |
| `aiops-tfstate-<account>-us-east-2` state bucket | Not used. This project has its own bucket |
| `aiops-github-plan` / `-apply` / `-image-push` roles | Untouched. Their trust is limited to the AIOps repository |
| `aiops-dev-workload-boundary` | Untouched. This project creates `idp-*` boundaries |
| ECR `aiops-sample-app` (image `v1`) | Untouched. This project uses `idp/<service>` repositories |
| Budget `aiops-account-monthly` ($30, account-wide) | Kept as the **account** guardrail; it already counts this project's spend |

The account is an AWS Organizations member, and an SCP explicitly denies regional services in
us-east-1 ([AIOps ADR 0003](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation/blob/main/docs/adr/0003-region-us-east-2.md)).

## Decision

1. Use the same account and **us-east-2 only**. The approved-Region list in `terraform/stack` and
   `terraform/bootstrap` is narrowed to `us-east-2`, and a test asserts that us-east-1 is rejected.
2. **Never manage, import, modify or delete any `aiops-*` resource or the OIDC provider.**
   `create_oidc_provider` defaults to `false` (data-source lookup), so destroying this project's
   bootstrap can never break AIOps CI.
3. **Separate everything else** by prefix: state bucket `idp-tfstate-<account>-us-east-2`, roles
   `idp-*`, ECR `idp/*`, tags `Project=idp`.
4. **Budgets:** keep `aiops-account-monthly` as the account-wide alert. Add only a **project-scoped**
   `idp` budget filtered on `Project=idp` (default $25), instead of a second account-wide budget that would duplicate alerts.
5. **OIDC subjects:** the AIOps repository uses immutable-ID subjects (`repo:<owner>@<id>/<repo>@<id>:…`).
   `iam-oidc` supports both formats; Phase 3 reads this repository's actual subject format from the
   GitHub API before writing any trust policy.
6. The account ID is still **not committed**. It reaches Terraform as `TF_VAR_aws_account_id`.

## Consequences

- **Cross-project blast radius (accepted risk, tracked as T23).** The AIOps apply role allows
  `ecs:*`, `elasticloadbalancing:*` and VPC writes on `*` in us-east-2, so a compromised or buggy
  AIOps pipeline could modify `idp-*` resources (the reverse will not be true: the `idp` apply role
  will be conditioned on `aws:ResourceTag/Project = idp` where the API supports it). Mitigations:
  AIOps workflows run only manually behind its `aws-dev` approval; the AIOps dev environment is
  destroyed. Recommended follow-up in the AIOps repository: add `aws:ResourceTag/Project = aiops`
  conditions. That is not changed from here, because it is out of this project's scope.
- The two `aiops`/`idp` budgets overlap by design: account total vs this project's share.
- Discovery still has to confirm the retained resources are as documented (`scripts/aws_discovery.sh us-east-2 us-east-1`).
  A us-east-1 deny in that report is expected and confirms the SCP.
- Moving to a dedicated account later changes only `TF_VAR_aws_account_id`, `backend.hcl` and `create_oidc_provider`.
