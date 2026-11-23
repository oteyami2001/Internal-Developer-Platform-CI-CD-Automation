## Summary

<!-- What changes and why. Link the issue or deployment request. -->

## Type of change

- [ ] Application code (`apps/`)
- [ ] Service manifest (`apps/*/service.yaml`)
- [ ] Platform guardrails (`platform/schemas`, `platform/policy`) - platform team review required
- [ ] Infrastructure (`terraform/`)
- [ ] CI/CD workflows (`.github/workflows`)
- [ ] Documentation

## Checklist

- [ ] `make check` passes locally (tests, lint, manifest validation, Terraform fmt/validate/test, Checkov)
- [ ] No credentials, account IDs, state files or plan files are committed
- [ ] Security exceptions (`checkov:skip`, `nosec`, `trivy:ignore`) include a written justification
- [ ] Infrastructure changes: the plan summary was reviewed (Phase 3+)
- [ ] Docs updated, and capabilities are labelled planned / implemented / tested / AWS-verified

## Rollback

<!-- How to undo this change if it misbehaves after deployment. -->
