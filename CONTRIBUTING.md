# Contributing

This is a personal lab, but issues and pull requests are welcome.

## Workflow

1. Branch from `main`. Direct commits to `main` are blocked by a pre-commit hook and by branch protection.
2. Install the hooks once: `pre-commit install` (installs the pre-commit and commit-msg hooks).
3. Use conventional commit messages: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`, `refactor:`, `test:`.
4. Open a pull request and fill in the template. Pull requests are squash-merged with the title as the commit.

## Run the checks locally

```bash
make verify      # offline: pytest, ruff, terraform fmt/validate/test/tflint, Checkov,
                 # shellcheck, shellharden, hadolint, actionlint and zizmor
make image       # build the image and gate it with Trivy (needs Docker)
make semgrep     # the Semgrep rulesets of the security gate
pre-commit run --all-files
```

None of these need AWS credentials. `terraform test` uses a mocked provider. `make test-live` is the only target
that touches AWS; the maintainer runs it by hand in a sandbox account (see the README).

## Rules for changes

- **Trust and permission policies.** Any change to `infra/terraform/policies/`, `infra/terraform/iam.tf` or
  `examples/gitlab-ci/terraform/` needs a matching assertion in the `*.tftest.hcl` next to it. A change to a
  recorded decision needs a new ADR in `docs/adr/`.
- **GitLab example.** Changes to `examples/gitlab-ci/.gitlab-ci.yml` keep `tests/test_gitlab_example.py` green: one
  job with `id_tokens`, images pinned by digest, no AWS keys.
- **Workflows.** Start from `permissions: {}` and grant per job. Pin every action and reusable workflow to a full
  commit SHA, with the version in a comment where one exists. Pass event data to scripts through `env`, not inline
  expressions. No `pull_request_target`. `tests/test_workflows.py`, `actionlint` and `zizmor` must pass.
- **Linting.** Fix findings; do not suppress them. A Checkov or Trivy skip is allowed only next to the resource,
  with the reason.
- **Content.** English, dateless, placeholders only (`OWNER/REPO`, `YOUR_STATE_BUCKET`); never a real account ID,
  ARN or IP address.

## Required status checks

Branch protection on `main` requires these checks, plus one approving review from a code owner. The `ci` jobs
marked "shared" call reusable workflows from `gamaware/.github`.

| Check | Workflow |
| --- | --- |
| `make verify` | `ci.yml` |
| `docs / markdownlint`, `docs / links`, `docs / vale` | `ci.yml` (shared `lint-docs`) |
| `actions / actionlint`, `actions / zizmor` | `ci.yml` (shared `lint-actions`) |
| `secrets / gitleaks` | `ci.yml` (shared `secrets`) |
| `container / hadolint`, `container / build-scan` | `ci.yml` (shared `container`) |
| `repo-scan / trivy` | `ci.yml` (shared `security`, Trivy on the repository) |
| `Semgrep (code)`, `Trivy (image)`, `Checkov (infra)` | `security.yml` (SARIF gates) |

The repository owner applies them with:

```bash
gh api --method PUT repos/OWNER/REPO/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "make verify",
      "docs / markdownlint", "docs / links", "docs / vale",
      "actions / actionlint", "actions / zizmor", "secrets / gitleaks",
      "container / hadolint", "container / build-scan", "repo-scan / trivy",
      "Semgrep (code)", "Trivy (image)", "Checkov (infra)"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "required_conversation_resolution": true,
  "required_linear_history": true,
  "restrictions": null
}
EOF
```

`Terraform plan (read-only)` is not required: it is skipped when the plan role is not configured and for fork pull
requests.

## Pre-commit hook updates

`update-pre-commit-hooks.yml` opens a weekly pull request with new hook versions. It reads the `PRE_COMMIT_PAT`
secret (a fine-grained token with contents and pull request write access to this repository) from an environment
named `automation`. Limit that environment's deployment branches to `main`, so a workflow changed on another branch
cannot read the token.
