# Dev deployment runbook (Phase 4)

Deploys the **dev environment infrastructure** through GitHub Actions only: no AWS keys, no console
changes. Every apply needs a reviewed plan and your approval of the `dev` environment.

| | |
|---|---|
| Prerequisites | Phase 3 bootstrap applied and verified (`verify_bootstrap.sh`: all PASS); GitHub environments configured (`verify_github_settings.sh`: all PASS) |
| Creates (infrastructure only) | VPC (2 AZs, public + private subnets, no NAT), flow logs, ALB (HTTP from your /32 only), target group, ECS cluster, SNS alerts + e-mail subscription, 4 alarms, ECS deployment-event rule + log group, dashboard |
| Not yet | The ECS **service**: it is created once Phase 5 publishes a digest-pinned image (`SERVICE_IMAGE_DIGEST`, [release-runbook.md](release-runbook.md)). Until then the ALB answers `503`. That is expected |
| Cost while it exists | ALB ≈ $0.0225/h + 2 public IPv4 ≈ $0.010/h, so **≈ $0.03/hour ≈ $0.80/day**. Everything else is free or cents. Tear down after the demo (Phase 7 `cleanup.yml`) |

## 0. One-time: give the plan job its inputs

The plan runs in `dev-plan`, the apply runs in `dev`, and both need your `/32` and the alert e-mail.
In the Codespace, signed in as yourself (`unset GITHUB_TOKEN && gh auth login`):

```bash
ALLOWED_INGRESS_CIDR=<your-ip>/32 scripts/configure_github_environments.sh <aws_account_id> <alert_email>
```

It is idempotent: it re-applies the environments and adds `ALLOWED_INGRESS_CIDR` and `ALERT_EMAIL`
to both `dev-plan` and `dev`. Check:

```bash
gh variable list --repo oteyami2001/Internal-Developer-Platform-CI-CD-Automation --env dev-plan
```

Home IP addresses change. Before a demo, compare with `curl -s https://checkip.amazonaws.com` and
re-run the command above if it differs.

## 1. Plan (read-only)

GitHub → **Actions → terraform-plan → Run workflow** (branch `main`).

The run summary shows:
- the `Plan:` line;
- every resource that will be created, changed or destroyed;
- the **plan digest**: a SHA-256 over every planned change.

Review it:
- [ ] `Plan: N to add, 0 to change, 0 to destroy` on the first run.
- [ ] Every address is under `module.network`, `module.load_balancer`, `module.ecs_cluster` or `module.observability` (no `module.service` until Phase 5).
- [ ] No `aiops` resource, and nothing destroyed.

The plan log shows `(sensitive value)` for your IP and e-mail, and `***` for the account ID.

## 2. Apply exactly that plan

**Actions → terraform-apply → Run workflow**, then paste the digest. Then **Review deployments → dev → Approve**.

The job re-plans first. If anything changed since your review (code on `main`, a variable, or
the real infrastructure), the digest differs and the job stops with
`Refusing to apply: the plan changed since it was reviewed`. Plan again and review again.

## 3. Verify

- [ ] The apply summary lists the outputs: `service_url`, `dashboard_name`, `ecs_cluster_name`, and so on.
- [ ] An e-mail **"AWS Notification - Subscription Confirmation"** arrives. Click *Confirm subscription*.
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' <service_url>/health` from your machine returns `503` (ALB up, no service yet). From any other network it **times out** (security group).
- [ ] In CloudWatch, the dashboard `idp-dev` exists and the alarms `idp-dev-*` are in OK or INSUFFICIENT_DATA.
- [ ] Re-run **terraform-plan**: it should say `No changes.` (no drift).

Send the plan line, the apply summary and these checks, and they go into `docs/portfolio-evidence.md`.

## 4. Tear down after the demo

Until `cleanup.yml` exists (Phase 7), stop the hourly cost with the same reviewed flow on a destroy
plan. Ask, and it will be prepared as a reviewed change rather than run by hand.
