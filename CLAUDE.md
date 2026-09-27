# CLAUDE.md

Portfolio lab for a CI/CD service: a container app deployed to Amazon ECS on Fargate from GitHub Actions with OIDC,
a least-privilege deploy role and security gates. `examples/gitlab-ci/` shows the same deploy from GitLab CI with
GitLab's OIDC tokens. Everything is verified offline; nothing in `make verify` calls AWS.

## Layout

- `app/`: Python standard-library HTTP service, its tests and the Dockerfile (base image pinned by digest).
- `infra/terraform/`: OIDC provider, deploy role, optional read-only plan role, ECR, ECS. Policies are JSON
  templates in `policies/`; `tests/iam.tftest.hcl` asserts them with a mocked provider.
- `examples/gitlab-ci/`: `.gitlab-ci.yml` plus `terraform/` for the GitLab OIDC provider and role, with its own
  mocked tests. `tests/test_gitlab_example.py` asserts the pipeline's security properties.
- `tests/`: repository-level tests (workflow and pipeline properties).
- `scripts/`: `verify-deployment.sh` (used by both pipelines) and `test-live.sh` (manual, real AWS).
- `docs/adr/`, `docs/diagrams/` (`.drawio` source plus exported PNG), `docs/threat-notes.md`,
  `docs/deploy-runbook.md`, `docs/jenkins-pattern.md`.

## Rules

- A change to a trust or permission policy needs a matching assertion in the relevant `*.tftest.hcl`. A change to a
  recorded decision needs a new ADR.
- Workflows: `permissions: {}` at the top, per-job grants, actions pinned to full SHAs, no `pull_request_target`,
  no `id-token` on pull request jobs.
- Checkov skips only inline with a reason. Never blanket-skip.
- `make test-live` touches the `dev` AWS profile. Never run it unless the maintainer asks; never commit its output.

## Commands

```bash
make verify          # everything CI runs, offline
make test            # pytest only
make terraform       # fmt, validate, test, tflint for both Terraform roots
pre-commit run --all-files
```

## Content

Fictional client "Harbor Goods", AWS documentation example IDs (`111122223333`) and `example.com` only. English,
dateless, Conventional Commits, no AI attribution.
