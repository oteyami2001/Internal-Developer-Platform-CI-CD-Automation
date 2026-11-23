# Developer guide

How a developer ships a service on the platform. Phase 1 covers the manifest, local checks and the
catalog. Template scaffolding (Phase 6) and the AWS deployment workflows (Phases 3–5) are marked 📋.

## 1. The service manifest

Every service lives in `apps/<name>/` and has one `service.yaml`. It is the **only** deployment
input a developer controls. Full schema: [`platform/schemas/service.schema.json`](../platform/schemas/service.schema.json).

```yaml
apiVersion: idp.platform/v1alpha1
kind: Service
metadata:
  name: orders-api            # 3-20 chars, lowercase, must match the directory name
  owner: team-payments        # must be an approved team
  description: Order management service.
  tier: standard              # experimental | standard | critical
  tags:
    cost-center: cc-1234      # extra tags only; platform tags cannot be overridden
spec:
  runtime: python3.13
  container:
    port: 8080                # 1024-65535
    cpu: 256                  # 256 | 512 | 1024
    memory: 512               # valid Fargate combination for the cpu
  healthCheck:
    path: /health
    intervalSeconds: 30
    healthyThreshold: 2
    unhealthyThreshold: 3
  deployment:
    strategy: rolling
    circuitBreakerRollback: true
    minimumHealthyPercent: 100
    maximumPercent: 200
  environments:
    dev:     { enabled: true,  desiredCount: 1 }
    staging: { enabled: false }
    prod:    { enabled: false, desiredCount: 2 }
  environmentVariables:       # NON-secret configuration only
    FEATURE_FLAG_X: "on"
  secrets:                    # resolved from Secrets Manager: idp/<env>/<service>/<secretName>
    - name: DB_PASSWORD
      secretName: orders-db
```

### What you can't do (by design)

| You can't… | Because… |
|---|---|
| Add IAM policies, security groups, CIDRs, regions, VPCs or any other AWS resource | The schema has no such fields and rejects unknown keys |
| Use a privileged port, an invalid Fargate size or a non-rolling strategy | Schema enums and ranges |
| Run more than 2 tasks or more than 0.5 vCPU in dev; fewer than 2 tasks in prod | Platform policy (cost and availability) |
| Put a password or token in `environmentVariables` | Secret-looking names and values are rejected; use `secrets` |
| Reference another service's secret or an arbitrary ARN | Secrets are short names, namespaced by the platform |
| Override `Project`, `Environment`, `Service`, `Owner`, `ManagedBy` tags | Reserved by the platform |

Defaults are applied for anything you omit (0.25 vCPU / 512 MiB, `/health`, rolling with circuit
breaker, 1 task).

## 2. Local workflow (works today)

**Python 3.13 is the project standard** ([ADR 0006](adr/0006-python-3-13-standard.md)). The easiest
setup is a **GitHub Codespace**: `.devcontainer/devcontainer.json` gives Python 3.13, the GitHub
CLI, Terraform 1.17.2 + TFLint and Docker, and installs the dev requirements. Rebuild an existing
Codespace (Command Palette → *Codespaces: Rebuild Container*) to pick it up. Locally,
`.python-version` pins 3.13 for pyenv/uv.

```bash
make install            # Python dev tooling
make validate-services  # schema + policy for every apps/*/service.yaml
make test               # unit tests (90% coverage gate)
make catalog            # regenerate platform/catalog/services.yaml after manifest changes
make check              # everything CI will run offline
```

See the exact settings the platform will deploy for an environment:

```bash
python3 scripts/validate_service.py --render dev apps/sample-api/service.yaml
```

Run the sample service:

```bash
cd apps/sample-api && uvicorn app.main:app --reload --port 8080   # http://localhost:8080/docs
make image smoke                                                  # hardened container test
```

## 3. Service contract (what the platform expects from your container)

| Requirement | Why |
|---|---|
| `GET <healthCheck.path>` returns 200 when the process is alive | ALB target health + container health check |
| `GET /ready` returns 503 while starting or draining | Readiness signal |
| Listens on `spec.container.port`, runs as non-root, tolerates a read-only root filesystem | Enforced by the task definition |
| Handles SIGTERM and drains within 20 s | ECS `stopTimeout` is 30 s |
| Logs JSON to stdout | CloudWatch Logs Insights queries |
| Reads build metadata from `APP_VERSION`, `GIT_SHA`, `BUILD_TIME` | `/version` proves which image runs |

## 4. Shipping a change 📋 (Phases 2–5)

1. Branch, change code and/or `service.yaml`, open a PR (template checklist).
2. `ci.yml` runs every check 🛠️; the single required status `ci-ok` blocks merge on any failure.
   Run `make check` first to see the same results locally.
3. Merge to `main`, then `image-build.yml` builds, scans and pushes, and records `image@sha256:…`.
4. Request a deployment (`app-deploy.yml`, or the deploy-request issue form in Phase 6) with that digest.
5. A reviewer approves the `dev-deploy` environment; the workflow deploys and reports health.
6. If the release is unhealthy, the ECS circuit breaker rolls back automatically
   (see [rollback-runbook.md](rollback-runbook.md)).

## 5. Creating a new service 📋 (Phase 6)

`scripts/new_service.py <name> --owner <team>` will copy `platform/templates/python-service` into
`apps/<name>`, fill in the manifest, and the catalog regenerates on the next `make catalog`.
