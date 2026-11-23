# Rollback runbook

> 📋 **Planned (Phase 7).** These procedures are designed but have not been executed against AWS.
> Each step will be rehearsed and timestamped in [portfolio-evidence.md](portfolio-evidence.md) before it is marked verified.

## 1. Decision table

| Symptom | First action | Section |
|---|---|---|
| New deployment never becomes healthy | Let the circuit breaker roll back; confirm | §2 |
| Deployment completed, but the new version misbehaves (5xx, latency) | Redeploy the previous digest | §3 |
| Infrastructure change broke something | Revert the commit, plan, approve, apply | §4 |
| Unknown or manual change in AWS (drift) | Do **not** auto-fix; investigate, then codify or revert via PR | §5 |
| Cost alarm | Approved cleanup | §6 |

## 2. Automatic: ECS deployment circuit breaker

Enabled with `rollback = true` on every service (mandatory in prod by policy). If new tasks fail
to reach a healthy, steady state, ECS marks the deployment `FAILED` and returns to the last
completed task definition.

Verify:

```bash
aws ecs describe-services --cluster idp-dev --services sample-api \
  --query 'services[0].deployments[].{status:status,rollout:rolloutState,reason:rolloutStateReason,td:taskDefinition}'
aws ecs describe-services --cluster idp-dev --services sample-api --query 'services[0].events[:10]'
```

Expected: a `PRIMARY` deployment on the previous task definition with rollout `COMPLETED`, and a
`FAILED` deployment with a circuit-breaker reason. The EventBridge rule (Phase 7) forwards the state
change to SNS and to a log group.

## 3. Manual: redeploy the last known-good digest

1. Find the previous good digest in the last successful `app-deploy` report, or:
   ```bash
   aws ecs describe-task-definition --task-definition sample-api:<previous-revision> \
     --query 'taskDefinition.containerDefinitions[0].image'
   ```
2. Run `app-deploy.yml` with `service=sample-api`, `environment=dev`, and `image_digest=<sha256:…>`.
3. Approve the `dev-deploy` environment.
4. The workflow waits for steady state and probes `/health` and `/version`. Confirm `/version`
   reports the expected `git_sha`.

Never roll back by pushing an old image under a new tag: tags are immutable, and deploys use digests.

## 4. Infrastructure rollback

1. `git revert <commit>` in a PR → CI.
2. Merge → `terraform-plan.yml` → review the plan (it should show only the reverted change).
3. Approve the `dev` environment → `terraform-apply.yml` applies the exact plan.
4. Never `terraform apply` without a plan, and never run `terraform destroy` as a rollback.

State recovery (last resort): the state bucket is versioned. Restore the previous object version of
`envs/<env>/terraform.tfstate` only after confirming that no apply is running (lock file absent),
and record why.

## 5. Drift

`drift-detection.yml` runs `terraform plan -detailed-exitcode` on a schedule. Exit code 2 opens an
issue with the plan summary. It **never applies**. Resolve the drift by either codifying the
manual change in Terraform (PR) or reverting it through the normal plan → approve → apply flow.

## 6. Cost emergency

Run `cleanup.yml`: review the destroy plan of the workload resources, approve, verify that no
ALB, ECS tasks, Elastic IPs or NAT gateways remain (`scripts/aws_discovery.sh` cost checks).
Bootstrap resources stay.
