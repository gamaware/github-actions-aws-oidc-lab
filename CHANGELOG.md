# Changelog

All notable changes to this lab. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- GitLab CI equivalent in `examples/gitlab-ci/`: a pipeline with the same build-once, scan, deploy-by-digest and
  verify stages, and a Terraform root for the GitLab OIDC provider and a deploy role that reuses the GitHub deploy
  policy ([ADR 0009](docs/adr/0009-gitlab-ci-example.md)).
- Jenkins pattern: [docs/jenkins-pattern.md](docs/jenkins-pattern.md).
- `make verify` (the offline checks CI runs) and `make test-live` (manual: apply both roots to a sandbox account,
  check the roles with the IAM policy simulator, always destroy).
- pytest suites for the workflow hardening rules and the GitLab pipeline's properties.
- Terraform outputs for the GitLab example and a `tags` variable.
- Social preview (`docs/assets/social-preview.png`, 1280x640) rendered from `docs/assets/social-preview.json`
  with the shared generator.
- Context and deployment diagrams with official AWS icons, the cover image, a deploy runbook, `CLAUDE.md`, editor
  hooks in `.claude/`, `.editorconfig`, `.coderabbit.yaml`, Copilot review instructions, Vale configuration and a weekly
  pre-commit hook update workflow (needs the `PRE_COMMIT_PAT` secret in an `automation` environment).

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

- Terraform moved from `infra/` to `infra/terraform/`, and `CODEOWNERS` to the repository root.
- `ci.yml` is a thin caller: `make verify` plus the shared `lint-docs`, `lint-actions`, `secrets`, `container` and
  `security` workflows, pinned to commit `1255caafb08b06cc4658318c4dd48f9dea946c9e` of `gamaware/.github`.
  `lint.yml` is removed; its checks run in `make verify`. Required check names changed (see CONTRIBUTING.md).
- Checkov in `security.yml` also scans `examples/gitlab-ci/terraform/`.
- The README follows the portfolio template; setup, repeatable checks, cost and teardown moved to
  [docs/deploy-runbook.md](docs/deploy-runbook.md).
- The HTTPS egress rule carries an inline Trivy exception with its reason (tasks reach ECR through NAT or a public
  IP).

Relative to the first draft of the lab:

- The deploy role trusts only the `production` environment subject; the `main` branch subject is gone
  ([ADR 0002](docs/adr/0002-environment-subject-only.md)). The `github_branch` variable is removed.
- The repository variable `ECR_REPOSITORY` is replaced by `ECR_REPOSITORY_URL` (Terraform output
  `ecr_repository_url`).
- Every workflow starts from `permissions: {}` and grants permissions per job.

### Fixed

- The Trivy gate failed on HIGH findings in pip's vendored packages. The runtime image no longer ships pip, which
  the standard-library app never used. The base image digest was already the latest `python:3.13-slim`.
