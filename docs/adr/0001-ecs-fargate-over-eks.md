# ADR 0001: ECS Fargate (not EKS) for the MVP runtime

- **Status:** Accepted (Phase 1 proposal; owner approval pending with the Phase 1 review)
- **Date:** 2026-11-23

## Context
The platform must demonstrate standardized, secure deployments at minimal cost. Demos are short;
the platform is not running continuously.

## Decision
Run workloads on **Amazon ECS with Fargate**: no nodes to patch, per-second billing, native ALB
integration, and a deployment circuit breaker with automatic rollback.

## Consequences
- No EKS control-plane charge (about $73/month on standard support, before any nodes).
- No Kubernetes-native tooling (Helm, admission controllers). The manifest schema plus the
  validator plays the admission-control role at PR time.
- Supported strategies are ECS **rolling** updates (blue/green via ECS native blue/green or
  CodeDeploy is a later extension; the schema already restricts `strategy` to `rolling`).
- EKS can become a second implementation track behind the same manifest contract.
