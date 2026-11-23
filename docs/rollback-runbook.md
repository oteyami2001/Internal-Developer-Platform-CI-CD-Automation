# Rollback runbook

> 🛠️✅ **Implemented and tested offline (Phase 7).** §3 (redeploy a digest) is ☁️ verified in Phase 5.
> The drill in §2, drift detection (§5) and cleanup (§6) are marked ☁️ in
> [portfolio-evidence.md](portfolio-evidence.md) once they have run in AWS.

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
`FAILED` deployment with a circuit-breaker reason. The EventBridge rule forwards the state change to
SNS (e-mail) and to the `/aws/events/idp-dev/ecs-deployments` log group.

### Drill: prove the circuit breaker works

1. **Actions → drill-image → Run workflow** (branch `main`). It builds
   `platform/drills/crash-on-start` (an image that exits with status 1 on start and contains no
   application code), **proves it crashes**, scans it, and publishes it as `drill-crash-<commit>`.
   Copy the digest from the summary.
2. **Actions → app-deploy → Run workflow** with that digest, then approve `dev-deploy`.
3. Expected within ~5 minutes:
   - the new tasks exit, ECS marks the deployment `FAILED` (circuit breaker) and rolls back;
   - **the app-deploy job fails** with the circuit-breaker reason. That failure is the success
     criterion; a "stable" result would mean the breaker did not work;
   - `/health` keeps answering `200` throughout (the old task keeps serving, minimum healthy 100%);
   - an e-mail from the alert topic reports the failed deployment.
4. Record the run, the times and the revisions in the evidence. Nothing needs undoing: the service is
   back on the last good revision.

## 3. Manual: redeploy the last known-good digest

1. Find the previous good digest in the last successful `app-deploy` report, or:
   ```bash
   aws ecs describe-task-definition --task-definition idp-dev-sample-api:<previous-revision> \
     --query 'taskDefinition.containerDefinitions[0].image'
   ```
2. Run `app-deploy.yml` (branch `main`) with `image_digest=<sha256:…>`.
3. Approve the `dev-deploy` environment.
4. The workflow waits for that deployment's rollout to complete and checks target health (the
   runner cannot reach the /32-restricted ALB). From your browser, confirm `/version` reports the
   expected `git_sha`. Details: [release-runbook.md](release-runbook.md).

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

`drift-detection.yml` runs every Monday at 07:17 UTC (and on demand) with the read-only plan role.
If real infrastructure differs from the code, it opens an issue **Drift detected: dev** (label
`drift`), or comments on the open one, listing resource addresses and actions (no values: issues are
public), and the run fails so you get a notification. It **never applies**.

Resolve the drift by either codifying the manual change in Terraform (PR), or restoring the code's
state: **terraform-plan** → review → **terraform-apply** with the digest → approve `dev`. Then run
drift-detection again (expected: "No drift") and close the issue.

## 6. Cost emergency

Remove the dev environment (stops the ~$1/day of ALB, Fargate and public IPv4 costs):

1. **Actions → terraform-plan → Run workflow**, `mode = destroy`. Review: every line is a `delete`
   of an `idp-dev` workload resource. Copy the plan digest.
2. **Actions → cleanup → Run workflow** with `plan_digest` and `confirm = destroy-dev`, then approve
   `dev`. The job refuses unless the digest matches the reviewed destroy plan (a normal apply digest
   never matches), destroys exactly that plan, then **verifies** that the Terraform state is empty
   and that the `idp-dev` load balancer no longer exists.
3. Kept: the bootstrap (state bucket, CloudTrail, CI roles, ECR images, budget). Rebuild any time
   with terraform-plan (`mode = apply`) → terraform-apply; `SERVICE_IMAGE_DIGEST` recreates the
   service with the first image, then release the current digest with app-deploy.
