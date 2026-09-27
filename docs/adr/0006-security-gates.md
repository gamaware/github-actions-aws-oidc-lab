# ADR 0006: Semgrep, Trivy and Checkov as required checks, with SARIF in code scanning

## Status

Accepted

## Context

The repository has three kinds of content an attacker or a mistake can use: application code and workflows, a
container image, and Terraform. Each has a mature open source scanner. A scanner that only prints to a log is easy
to ignore; one that blocks the merge and files its findings where reviewers look is not.

## Decision

The `security` workflow runs three jobs on every pull request, on every push to `main`, and weekly:

| Check name | Scanner | Scope | Fails on |
| --- | --- | --- | --- |
| `Semgrep (code)` | Semgrep, rulesets `p/python`, `p/dockerfile`, `p/github-actions`, `p/terraform`, `p/secrets` | whole repository | any finding |
| `Trivy (image)` | Trivy | the built image | HIGH or CRITICAL with a released fix (`ignore-unfixed`) |
| `Checkov (infra)` | Checkov | `infra/terraform/` and `examples/gitlab-ci/terraform/` | any failed check without an inline skip |

Each job uploads SARIF to GitHub code scanning with its own category, even when the gate fails. The three check
names are required status checks on `main`, next to the `ci` workflow's `make verify` and
the shared checks it calls (see CONTRIBUTING.md).

Tool versions are pinned (`semgrep==1.178.0`, `checkov==3.3.19`, the Trivy action by commit SHA). Rulesets are named
explicitly instead of `--config auto`, so the rules do not depend on detection and metrics stay off.

## Consequences

- Trivy gates only on fixable findings. An unfixed CVE in the base image does not block every merge; a Dependabot
  digest bump brings the fix, and the weekly run reports new CVEs in an unchanged image. The first version failed
  on HIGH findings in pip's vendored packages; the runtime image now removes pip, which the app does not use.
- Every Checkov skip must sit next to the resource with its reason (see the KMS key policy in `infra/terraform/main.tf`).
- Fork pull requests get a read-only token, so their SARIF upload is skipped by GitHub. The gates still run and
  still block.
- Registry rulesets can gain rules between runs. A new Semgrep finding can fail a pull request that did not change
  the flagged code; fix it or pin a local rules file.

## Compliance

- Branch protection on `main` lists the three check names as required. This is a repository setting, applied with
  the `gh api` command in [CONTRIBUTING.md](../../CONTRIBUTING.md).
- Findings are visible in the Security tab, filtered by category `semgrep`, `trivy-image` or `checkov-infra`.

## Notes

- The same scanners run locally: `make verify` and `make semgrep` (see "Verify locally" in the README and CONTRIBUTING.md).
