# Changelog

All notable changes to this lab. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- The lab: a GitHub OIDC provider, a deploy role scoped to one ECR repository and one ECS service, a Fargate
  service, pull request CI with no cloud access, and threat notes.
- Security gates as required checks with SARIF in code scanning: Semgrep on code, Trivy on the image, Checkov on
  `infra/terraform/` ([ADR 0006](docs/adr/0006-security-gates.md)).
- Build once and deploy by digest: the image is built once as an OCI archive, scanned, attested (build provenance
  and SBOM), pushed with its digest preserved, and deployed as `image@sha256:<digest>`
  ([ADR 0005](docs/adr/0005-build-once-deploy-by-digest.md)).
- Post-deploy verification (`scripts/verify-deployment.sh`): the new revision is PRIMARY, its rollout completed, and
  its tasks are healthy on the expected digest.
- Offline IAM tests with `terraform test` and a mocked provider ([ADR 0008](docs/adr/0008-offline-policy-tests.md)).
- Optional read-only plan role and `plan` workflow for pull requests that change `infra/terraform/`, with an S3 backend
  example ([ADR 0007](docs/adr/0007-read-only-plan-role.md)).
- tflint and `terraform test` in CI; Terraform pinned in `infra/terraform/.terraform-version`.
- OpenSSF Scorecard workflow.
- ADRs, CODEOWNERS, SECURITY.md, CONTRIBUTING.md, a pull request template and this changelog.

### Changed

Relative to the first draft of the lab:

- The deploy role trusts only the `production` environment subject; the `main` branch subject is gone
  ([ADR 0002](docs/adr/0002-environment-subject-only.md)). The `github_branch` variable is removed.
- The repository variable `ECR_REPOSITORY` is replaced by `ECR_REPOSITORY_URL` (Terraform output
  `ecr_repository_url`).
- Every workflow starts from `permissions: {}` and grants permissions per job.

### Fixed

- The Trivy gate failed on HIGH findings in pip's vendored packages. The runtime image no longer ships pip, which
  the standard-library app never used. The base image digest was already the latest `python:3.13-slim`.
