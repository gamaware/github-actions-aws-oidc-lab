# Changelog

This file records all notable changes to this lab. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- AWS-native path in `examples/codepipeline/`: a CodePipeline V2 (Source through CodeConnections or S3, CodeBuild
  test, Trivy gate and push by digest, manual approval, ECS deploy action, CodeBuild verify), buildspecs, a pipeline
  KMS key for artifacts and build logs, an artifact bucket with a lifecycle rule and a TLS-only policy, and separate
  pipeline, build and verify roles ([ADR 0010](docs/adr/0010-github-actions-vs-codepipeline.md)).
- Offline tests for it: `examples/codepipeline/terraform/tests/codepipeline.tftest.hcl` (stages, approval before
  deploy, encryption, no wildcard actions) and `tests/test_codepipeline_example.py` (buildspec properties), both in
  `make verify`; Checkov in `security.yml` scans the new root.
- `make test-live-codepipeline` (manual): applies the deploy target and the pipeline to a sandbox account, runs the
  pipeline end to end with an S3 source, checks the roles with the IAM policy simulator, always destroys.
- CodePipeline flow diagram (`docs/diagrams/codepipeline-flow.drawio` and `.png`).
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
- Context and deployment diagrams with official AWS icons, the cover image, a deploy runbook, editor hooks,
  `.editorconfig`, `.coderabbit.yaml`, Copilot review instructions, Vale configuration and a weekly
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
- ADRs, CODEOWNERS, SECURITY.md and this changelog.

### Changed

- Terraform moved from `infra/` to `infra/terraform/`, and `CODEOWNERS` to the repository root.
- `ci.yml` is a thin caller: `make verify` plus the shared `lint-docs`, `lint-actions`, `secrets`, `container` and
  `security` workflows, pinned to commit `1255caafb08b06cc4658318c4dd48f9dea946c9e` of `gamaware/.github`.
  `lint.yml` is removed; its checks run in `make verify`. The caller jobs are `verify`, `lint-docs`, `lint-actions`,
  `secrets`, `container` and `security`, so the required check names match the other portfolio repositories (see the
  README's gates table).
- Checkov in `security.yml` also scans `examples/gitlab-ci/terraform/`.
- Trivy runs from the checksum-verified release binary (0.74.0) in `deploy.yml` and `security.yml`, not from the
  Trivy action.
- Terraform is pinned to 1.14.5 in each root's `.terraform-version`; every root requires 1.11 or later.
- ADRs use the `# NNNN. Title` heading; `SECURITY.md` points to the shared policy; `make verify` ends with
  `verify: all checks passed`.
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

### Removed

- `CONTRIBUTING.md` and the pull request template: inherited from `gamaware/.github`. The required checks moved to the
  README and the branch protection command to the deploy runbook.

### Fixed

- The Trivy gate failed on HIGH findings in pip's vendored packages. The runtime image no longer ships pip, which
  the standard-library app never used. The base image digest was already the latest `python:3.13-slim`.
