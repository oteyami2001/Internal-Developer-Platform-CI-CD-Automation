# Local developer entry points. Everything here runs OFFLINE: no AWS credentials, no deployments.
# CI (Phase 2) calls the same targets so local and pipeline results match.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

PYTHON    ?= python3
IMAGE     ?= sample-api:local
TF_DIRS   := terraform/bootstrap terraform/stack $(wildcard terraform/modules/*)
ENVS      := dev staging prod
export CHECKPOINT_DISABLE := 1

.PHONY: help install lint lint-workflows test validate-services catalog catalog-check tf-fmt tf-validate \
        tf-test tf-env-data tflint image smoke security checkov-guard check test-apps

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

install: ## Install Python dev tooling
	$(PYTHON) -m pip install -r requirements-dev.txt

lint: ## Ruff lint + format check, Bandit SAST
	ruff check .
	ruff format --check .
	bandit -q -c pyproject.toml -r apps scripts

checkov-guard: ## Fail if Checkov's GitHub Actions scan evaluated zero checks (a silent schema skip)
	BC_SKIP_MAPPING=TRUE checkov -d . --framework github_actions -o json --quiet --soft-fail \
	  | $(PYTHON) -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; s=d.get("summary",d); n=s.get("passed",0)+s.get("failed",0); print(f"checkov github_actions checks evaluated: {n}"); sys.exit(0 if n else 1)'

lint-workflows: ## actionlint + zizmor (GitHub Actions correctness and security) + shellcheck
	actionlint
	zizmor --offline --min-severity low .github/workflows
	shellcheck -S warning scripts/*.sh

test: ## Platform tests + every service's own tests, each with a 90% coverage gate
	$(PYTHON) -m pytest --cov --cov-report=term-missing
	$(MAKE) --no-print-directory test-apps

test-apps: ## Each apps/<service> tested on its own (own pyproject.toml); JUNIT_DIR=dir adds junit-<service>.xml
	$(PYTHON) scripts/test_services.py

validate-services: ## Validate every apps/*/service.yaml against schema + platform policy
	$(PYTHON) scripts/validate_service.py apps/*/service.yaml

catalog: ## Regenerate platform/catalog/services.yaml
	$(PYTHON) scripts/generate_catalog.py

catalog-check: ## Fail if the committed catalog is stale
	$(PYTHON) scripts/generate_catalog.py --check

tf-fmt: ## terraform fmt check
	terraform fmt -check -recursive -diff terraform

tf-validate: ## terraform init (no backend; committed lock files are read-only) + validate everywhere
	@for d in $(TF_DIRS); do \
	  echo "== $$d"; \
	  lock=""; if [ -f $$d/.terraform.lock.hcl ] && git ls-files --error-unmatch $$d/.terraform.lock.hcl >/dev/null 2>&1; then lock="-lockfile=readonly"; fi; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color $$lock >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	done

tf-test: tf-validate ## terraform test (mocked AWS provider) where tests exist
	@for d in $(TF_DIRS); do \
	  if ls $$d/tests/*.tftest.hcl >/dev/null 2>&1; then echo "== $$d"; terraform -chdir=$$d test -no-color; fi; \
	done

tf-env-data: tf-validate ## Validate each committed terraform/envs/<env>/terraform.tfvars against the stack guardrails
	@for e in $(ENVS); do \
	  echo "== env $$e"; \
	  terraform -chdir=terraform/stack test -no-color -test-directory=tests/env-data -var-file=../envs/$$e/terraform.tfvars; \
	done

tflint: ## TFLint (terraform + AWS rulesets) across all Terraform
	tflint --init --config "$(CURDIR)/.tflint.hcl"
	tflint --recursive --config "$(CURDIR)/.tflint.hcl" --chdir terraform --format compact

image: ## Build the sample-api image (one plain image manifest: no attestation index, see push_image.sh)
	docker build --provenance=false --sbom=false \
	  --build-arg APP_VERSION=$$(git describe --tags --always 2>/dev/null || echo 0.0.0-dev) \
	  --build-arg GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
	  --build-arg BUILD_TIME=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	  -t $(IMAGE) apps/sample-api

smoke: ## Run the image hardened (read-only FS, no capabilities) and probe its endpoints
	docker rm -f idp-smoke >/dev/null 2>&1 || true
	docker run -d --name idp-smoke --read-only --cap-drop ALL --security-opt no-new-privileges -p 18080:8080 $(IMAGE)
	for i in $$(seq 1 30); do curl -fsS localhost:18080/health >/dev/null && break; sleep 1; done
	test "$$(docker exec idp-smoke id -u)" = "10001"
	curl -fsS localhost:18080/ready
	curl -fsS localhost:18080/version
	docker stop -t 30 idp-smoke >/dev/null
	test "$$(docker inspect -f '{{.State.ExitCode}}' idp-smoke)" = "0"
	docker rm idp-smoke >/dev/null
	@echo "smoke test passed"

security: ## Checkov (IaC, Dockerfile, GitHub Actions, secrets) - same frameworks as CI
	BC_SKIP_MAPPING=TRUE checkov -d . --framework terraform,dockerfile,github_actions,secrets --quiet --compact --skip-path '\.terraform'

check: lint lint-workflows test validate-services catalog-check tf-fmt tf-test tf-env-data tflint security checkov-guard ## Everything CI runs offline (except the image build + Trivy)
