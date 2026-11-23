# Release runbook (Phase 5): image build and deployment

How an application change reaches the dev ECS service. Every step runs in GitHub Actions with
short-lived OIDC credentials. Nobody holds AWS keys, and nothing is deployed without the owner's
approval of the `dev-deploy` environment.

```text
PR (ci-ok) ─merge─▶ image-build.yml ─digest─▶ app-deploy.yml ─approval─▶ ECS rolling deploy ─▶ verified
                    build · smoke · Trivy      dev-deploy env          circuit breaker   rollout COMPLETED
                    SBOM · push (immutable)    (required reviewer)     + rollback        + healthy targets
```

| Workflow | Trigger | Role (trust) | Can | Cannot |
|---|---|---|---|---|
| `image-build.yml` | push to `main` touching `apps/sample-api/**`, or manual on `main` | `idp-github-image-push` (`ref:refs/heads/main`) | push to `idp/*` ECR repositories | deploy, read state, change infrastructure |
| `app-deploy.yml` | manual on `main`, input `image_digest` | `idp-dev-github-deploy` (`environment:dev-deploy`) | register `idp-dev-*` task definitions, update services in cluster `idp-dev`, pass the service's own roles to ECS | Terraform state, infrastructure, IAM changes, other clusters |
| `terraform-plan/apply.yml` | manual on `main` | plan / apply roles | first creation of the service (below) | — |

## Release ownership

- **Terraform** creates the ECS service once, with the initial image `SERVICE_IMAGE_DIGEST`, and
  owns everything about it: CPU, memory, roles, network, user, read-only filesystem, logging.
- **app-deploy** owns releases. It copies the family's latest task-definition revision and
  changes **only the image**. The service ignores task-definition changes in Terraform
  (`lifecycle.ignore_changes`), so a later `terraform plan` stays at "No changes".
- `tf_ci.sh` **refuses any plan that would delete the running ECS service**, for example if
  `SERVICE_IMAGE_DIGEST` were removed. Removing an environment is a cleanup decision (Phase 7).

## 1. Publish an image

Merging a change under `apps/sample-api/` to `main` starts **image-build** automatically. For the
first image, start it by hand: **Actions → image-build → Run workflow** (branch `main`).

The run summary shows the **digest** (`sha256:…`). Copy it. The job publishes it only after the
image passed:
- the hardened smoke test (read-only filesystem, no capabilities, UID 10001, graceful stop);
- the Trivy gate (no HIGH/CRITICAL vulnerability that has a fix).

A CycloneDX SBOM is attached to the run as an artifact (`sbom-sample-api-<commit>`). The tag
`git-<commit>` is immutable: re-running the same commit never overwrites the published image.

## 2. First release only: create the ECS service with Terraform

The service does not exist yet, so app-deploy will refuse ("first release is created by
Terraform"). Once:

1. **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   `SERVICE_IMAGE_DIGEST` = the digest from step 1 (`sha256:…`, no repository, no tag).
2. Run **terraform-plan**. Expected: about **7 to add, 0 to change, 0 to destroy**, all under
   `module.service[0]`: log group, execution role + policy, task role, task security group, task
   definition, ECS service. Nothing outside `module.service[0]` changes.
3. Run **terraform-apply** with that plan's digest and approve `dev`. The apply waits until the
   service is stable (`wait_for_steady_state`).
4. Check: `http://<service_url>/health` from your browser shows `{"status":"ok"}` instead of `503`.

Leave `SERVICE_IMAGE_DIGEST` as it is afterwards. Releases do not change it.

## 3. Release (every later change)

1. **Actions → app-deploy → Run workflow** (branch `main`), `image_digest` = the digest.
2. The run waits for approval. **Review deployments → dev-deploy → Approve.** Rejecting it, or
   running it from any other branch, means the job never receives AWS credentials.
3. The job ([scripts/app_deploy.sh](../scripts/app_deploy.sh)):
   - checks that the digest exists in `idp/sample-api` (only image-build can push there);
   - checks that the service exists (it never creates infrastructure);
   - registers a revision with only the image changed and updates the service;
   - waits for **that** deployment's `rolloutState`. If the circuit breaker rolls back, the job
     **fails**. A plain "services-stable" wait would pass, because the old revision is stable again;
   - checks that the new revision is the PRIMARY deployment and the target group has healthy
     targets.
4. The summary records the digest, tags, ECR scan result, `revision N → N+1`, rollout state,
   healthy targets and duration.

The runner cannot call `/health` itself, because the ALB only accepts your /32 (SE-2). The ALB's
own health checks against `/health` are what make targets "healthy". Probe it from your browser
for the evidence.

## 4. Rollback

Run **app-deploy** with the **previous** digest. Find it in the previous successful app-deploy
summary, or in ECR (images are kept for rollback by the lifecycle policy). A failed deployment
has already been rolled back automatically by the circuit breaker. See also
[rollback-runbook.md](rollback-runbook.md).

## 5. Evidence for the portfolio

- image-build run: digest, Trivy result, SBOM artifact.
- terraform-plan/apply: the `module.service[0]` creation, then a re-plan with "No changes".
- app-deploy run waiting for approval (screenshot), then the approved run's summary.
- A rejected or non-`main` app-deploy run: no credentials, no change (scenario 7).
- `/health` returning 200 in the browser; the `ecs-deployments` log group showing the
  deployment events.
