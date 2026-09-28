# 0011. Ship the pull request plan workflow as a client-installed example

## Status

Accepted. Amends where [ADR 0007](0007-read-only-plan-role.md) puts the `plan` workflow; the plan role is unchanged.

## Context

ADR 0007 added a read-only plan role and a `plan` workflow in `.github/workflows/`. The workflow requested
`id-token: write` on `pull_request` and assumed the plan role when the repository variable `AWS_PLAN_ROLE_ARN` was
set. The README states that a pull request cannot obtain AWS credentials and that CI checks never touch AWS. An active
pull request workflow that can hold an OIDC token contradicts both statements, even while it is switched off by a
missing variable.

## Decision

- Move the workflow to `examples/workflows/plan.yml`. GitHub does not run workflows outside `.github/workflows/`.
- Keep the plan role in `infra/terraform/` behind `create_plan_role = false`, with its offline tests.
- Document the example as something a client copies into their own repository after creating the role
  ([deploy runbook](../deploy-runbook.md), step 6).

## Consequences

- No pull request in this repository can request an OIDC token. The README statements hold without exceptions.
- actionlint and zizmor in `make verify` scan `.github/workflows/` only, so they no longer check the example. The
  pytest hardening rules still apply to it (empty default permissions, no `pull_request_target`, job timeouts,
  actions pinned to full SHAs).
- A client who installs it accepts the trade-off ADR 0007 records: same-repository pull requests can read the stack's
  configuration and state.

## Compliance

`tests/test_workflows.py`:

- `test_the_cloud_plan_workflow_is_only_an_example` fails if `plan.yml` returns to `.github/workflows/`.
- `test_no_pull_request_workflow_requests_an_id_token` fails if any active pull request workflow asks for
  `id-token: write`, with no exceptions.
- The hardening tests run on `examples/workflows/*.yml` as well as on the active workflows.

## Notes

- The installed path, `.github/workflows/plan.yml`, stays in the example's `paths` filter so the workflow runs when
  it changes.
