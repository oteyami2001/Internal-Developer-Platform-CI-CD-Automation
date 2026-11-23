# Bootstrap runbook (Phase 3)

Creates the account-level foundation **once**, from **AWS CloudShell in us-east-2**, as the existing
administrator role (`AccountFullAccessRole`). No access keys are created or stored anywhere.
Everything after this runs through GitHub Actions with OIDC roles.

| | |
|---|---|
| What gets created | 28 resources: state bucket (7), CloudTrail trail + bucket (8), `idp-dev-workload-boundary` (1), 4 OIDC roles + 4 inline policies (8), ECR `idp/sample-api` (3), budget `idp-project-monthly` (1) |
| What is NOT touched | The shared GitHub OIDC provider (looked up only), every `aiops-*` resource, the `aiops-account-monthly` budget |
| Cost | Well under $1/month: S3 storage of state and logs, plus ECR storage once images exist. IAM, budget and the first CloudTrail copy of management events are free |
| Time | ~15 minutes |
| Prerequisite | The Phase 3 PR is merged into `main` (the code you run is the reviewed code) |

## 1. Open CloudShell

AWS Console → Region **US East (Ohio)** → `>_` (CloudShell). Confirm the account:

```bash
aws sts get-caller-identity --query '[Account, Arn]' --output text
```

## 2. Install Terraform (checksum-verified, on the temporary disk)

CloudShell's persistent home is only 1 GB, and the AWS provider unpacks to several hundred MB.
Terraform and the provider go on `/tmp`; only the small state file stays in your home directory.

```bash
cd /tmp && V=1.17.2 && ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && curl -sSfO "https://releases.hashicorp.com/terraform/${V}/terraform_${V}_linux_${ARCH}.zip" && curl -sSfO "https://releases.hashicorp.com/terraform/${V}/terraform_${V}_SHA256SUMS" && grep "linux_${ARCH}.zip" "terraform_${V}_SHA256SUMS" | sha256sum -c - && unzip -o -q "terraform_${V}_linux_${ARCH}.zip" -d /tmp/tfbin
```

```bash
export PATH=/tmp/tfbin:$PATH TF_DATA_DIR=/tmp/tfdata CHECKPOINT_DISABLE=1 && terraform version
```

If CloudShell restarts (idle timeout), `/tmp` is wiped: repeat step 2, then `terraform init` (step 4).
Your local state in the home directory is not affected.

## 3. Get the reviewed code

```bash
cd ~ && git clone https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation.git && cd Internal-Developer-Platform-CI-CD-Automation/terraform/bootstrap && git log --oneline -1
```

## 4. Inputs and init

Values that identify you are passed as environment variables, never written to a file:

```bash
export TF_VAR_aws_account_id=$(aws sts get-caller-identity --query Account --output text)
```

```bash
read -r -p "Alert e-mail: " TF_VAR_alert_email && export TF_VAR_alert_email
```

```bash
terraform init -input=false -lockfile=readonly
```

## 5. Plan and review

```bash
set -o pipefail; terraform plan -input=false -no-color -out=bootstrap.tfplan | tee plan.txt | tail -5; echo "plan exit code: $?"
```

`plan exit code: 0` is required. (`pipefail` makes a failed plan visible through the pipe, a
lesson from the previous project.)

Expected: **`Plan: 28 to add, 0 to change, 0 to destroy.`** Then check what will be created:

```bash
grep -E '^  # .* will be created' plan.txt | sed 's/ will be created//'
```

```bash
grep -E '^  # ' plan.txt | grep -ci aiops
```

Review before applying:
- Every resource is `idp-*`, or belongs to the `idp/sample-api` repository.
- The second command prints `0`: no resource being created, changed or destroyed is an AIOps
  resource. (`aiops` does appear inside the apply role's policy JSON. Those are the *deny*
  statements that protect the AIOps resources.)
- Nothing is changed or destroyed.

If the plan fails with an `explicit deny in a service control policy`, **stop and share the
message**. Never try to work around an SCP.

## 6. Apply exactly the reviewed plan

```bash
terraform apply -input=false bootstrap.tfplan
```

Run it **once**. A second run reports `Saved plan is stale` and changes nothing: the plan was
already applied.

If the apply stops partway (for example on an SCP deny), the created resources stay in the local
state. Re-running steps 5–6 continues from there; nothing is created twice.

## 7. Move the bootstrap state into S3

```bash
B="idp-tfstate-$(aws sts get-caller-identity --query Account --output text)-us-east-2" && cp backend.tf.example backend.tf && terraform init -migrate-state -force-copy -backend-config="bucket=$B" && aws s3 ls "s3://$B/bootstrap/"
```

Expected: `Successfully configured the backend "s3"!` and a listing that ends in `terraform.tfstate`.

Lessons from the first real run (2026-11-23), all recoverable because the local state stays
untouched until a migration succeeds:
- Build the bucket name from the account ID. `terraform output` fails once `backend.tf` exists.
- Without `-backend-config`, Terraform *prompts for the bucket name*. Typing `yes` there makes it try a bucket named "yes".
- `-input=false` is refused for a migration. `-force-copy` is the non-interactive approval.

Answer `yes`. Then confirm the state is in S3:

```bash
aws s3 ls "s3://$(terraform output -raw state_bucket)/bootstrap/"
```

Once `terraform.tfstate` appears in that listing, the local copies (`terraform.tfstate*` in this
directory) are redundant. Delete them yourself when you are satisfied. `backend.tf` is git-ignored.

## 8. Verify (read-only)

```bash
bash ../../scripts/verify_bootstrap.sh
```

Expected: `RESULT: all checks passed`. CloudTrail's first log delivery can take ~15 minutes.

## 9. GitHub environments (from your Codespace, signed in as yourself)

```bash
unset GITHUB_TOKEN && gh auth login
```

```bash
scripts/configure_github_environments.sh <aws_account_id> <alert_email>
```

```bash
scripts/verify_github_settings.sh
```

Expected: `dev` and `dev-deploy` require you as reviewer, and all three environments deploy only from `main`.

## 10. Activate the cost allocation tag (management account)

The project budget filters on the `Project` tag. In an AWS Organization, only the **management
account** can activate cost allocation tags: **Billing and Cost Management → Cost allocation tags →
`Project` → Activate**. The tag appears there up to 24 hours after the first tagged resource exists.
Until then the `idp` budget reads $0, and the `aiops-account-monthly` budget remains the backstop.

## 11. Evidence

Paste into the chat (or `docs/portfolio-evidence.md`):
- the `Plan:` line from step 5;
- the apply summary from step 6;
- the output of step 8;
- the output of step 9.

## Removing the bootstrap (end of project only)

The state and CloudTrail buckets have `prevent_destroy` and the trail bucket denies log deletion:
removing them is deliberately a manual, multi-step decision. Destroy every environment first
(`cleanup.yml`), then remove `prevent_destroy`, empty the buckets, and `terraform destroy` with
reviewed plans. The shared OIDC provider is never destroyed by this project.
