# Local developer entry points. Everything here runs OFFLINE: no AWS credentials, no deployments.
# CI (Phase 2) calls the same targets so local and pipeline results match.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

PYTHON    ?= python3
IMAGE     ?= sample-api:local
TF_DIRS   := terraform/bootstrap terraform/stack $(wildcard terraform/modules/*)
export CHECKPOINT_DISABLE := 1

.PHONY: help install lint test validate-services catalog catalog-check tf-fmt tf-validate tf-test \
        image smoke security check

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

install: ## Install Python dev tooling
	$(PYTHON) -m pip install -r requirements-dev.txt

lint: ## Ruff lint + format check, Bandit SAST
	ruff check .
	ruff format --check .
	bandit -q -c pyproject.toml -r apps scripts

test: ## Unit tests with coverage gate (90%)
	$(PYTHON) -m pytest --cov --cov-report=term-missing

validate-services: ## Validate every apps/*/service.yaml against schema + platform policy
	$(PYTHON) scripts/validate_service.py apps/*/service.yaml

catalog: ## Regenerate platform/catalog/services.yaml
	$(PYTHON) scripts/generate_catalog.py

catalog-check: ## Fail if the committed catalog is stale
	$(PYTHON) scripts/generate_catalog.py --check

tf-fmt: ## terraform fmt check
	terraform fmt -check -recursive -diff terraform

tf-validate: ## terraform init (no backend) + validate for every root and module
	@for d in $(TF_DIRS); do \
	  echo "== $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	done

tf-test: tf-validate ## terraform test (mocked AWS provider) where tests exist
	@for d in $(TF_DIRS); do \
	  if ls $$d/tests/*.tftest.hcl >/dev/null 2>&1; then echo "== $$d"; terraform -chdir=$$d test -no-color; fi; \
	done

image: ## Build the sample-api image
	docker build \
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

security: ## Checkov (IaC + Dockerfile + secrets); Trivy runs in CI (Phase 2)
	BC_SKIP_MAPPING=TRUE checkov -d . --framework terraform,dockerfile,secrets --quiet --compact --skip-path '\.terraform'

check: lint test validate-services catalog-check tf-fmt tf-test security ## Everything CI runs offline
