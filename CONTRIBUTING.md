# Contributing

This is a personal lab, but issues and pull requests are welcome.

## Workflow

1. Branch from `main`. Direct commits to `main` are blocked by a pre-commit hook and by branch protection.
2. Install the hooks once: `pre-commit install` (installs the pre-commit and commit-msg hooks).
3. Use conventional commit messages: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`, `refactor:`, `test:`.
4. Open a pull request and fill in the template. Pull requests are squash-merged with the title as the commit.

## Run the checks locally

```bash
uvx --with-requirements app/requirements-dev.txt pytest -q
docker build -t oidc-lab app
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 oidc-lab
(cd infra && terraform init -backend=false && terraform validate && terraform test)
(cd infra && tflint --init --config .tflint.hcl && tflint --config .tflint.hcl)
uvx checkov==3.3.19 --directory infra --framework terraform --quiet --compact
uvx semgrep==1.178.0 scan --metrics=off --error \
  --config p/python --config p/dockerfile --config p/github-actions --config p/terraform --config p/secrets
pre-commit run --all-files
```

None of these need AWS credentials. `terraform test` uses a mocked provider.

## Rules for changes

- **Trust and permission policies.** Any change to `infra/policies/` or `infra/iam.tf` needs a matching assertion
  in `infra/tests/iam.tftest.hcl`. A change to a recorded decision needs a new ADR in `docs/adr/`.
- **Workflows.** Start from `permissions: {}` and grant per job. Pin every action to a full commit SHA with the
  version in a comment. Pass event data to scripts through `env`, not inline expressions. No
  `pull_request_target`. `actionlint` and `zizmor` must pass.
- **Linting.** Fix findings; do not suppress them. A Checkov skip is allowed only next to the resource, with the
  reason.
- **Content.** English, dateless, placeholders only (`OWNER/REPO`, `YOUR_STATE_BUCKET`); never a real account ID,
  ARN or IP address.

## Required status checks

Branch protection on `main` requires these checks, plus one approving review from a code owner:

| Check | Workflow |
| --- | --- |
| `Unit tests` | `ci.yml` |
| `Dockerfile lint` | `ci.yml` |
| `Shell scripts` | `ci.yml` |
| `actionlint and zizmor` | `lint.yml` |
| `Terraform fmt, validate, test and tflint` | `lint.yml` |
| `Semgrep (code)` | `security.yml` |
| `Trivy (image)` | `security.yml` |
| `Checkov (infra)` | `security.yml` |

The repository owner applies them with:

```bash
gh api --method PUT repos/OWNER/REPO/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Unit tests", "Dockerfile lint", "Shell scripts",
      "actionlint and zizmor", "Terraform fmt, validate, test and tflint",
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
