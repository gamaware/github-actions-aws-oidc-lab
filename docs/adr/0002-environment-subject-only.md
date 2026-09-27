# ADR 0002: Trust only the environment subject, not the branch subject

## Status

Accepted. Supersedes the first version of the lab, which also trusted `repo:OWNER/REPO:ref:refs/heads/main`.

## Context

A job gets one of several `sub` forms, chosen by GitHub from the job's context:

| Job | `sub` |
| --- | --- |
| Declares `environment: production` | `repo:OWNER/REPO:environment:production` |
| On `main`, no environment | `repo:OWNER/REPO:ref:refs/heads/main` |
| Pull request | `repo:OWNER/REPO:pull_request` |

The first version trusted both the environment subject and the `main` branch subject. The branch subject lets any
job on `main` assume the deploy role, including a job that does not declare the environment and so skips the
required reviewer. Branch protection limits who can add such a job, but the reviewer gate becomes optional.

The deploy workflow now has a second job that needs an OIDC token on `main` for a different reason: `build` signs
the provenance and SBOM attestations with Sigstore, which needs `id-token: write`. With the branch subject trusted,
that job could also assume the deploy role, before anyone approves anything.

Keeping the branch subject would help one case: a workflow on `main` that deploys without a reviewer, for example a
scheduled redeploy. The lab has no such workflow.

## Decision

The deploy role trusts exactly one subject: `repo:OWNER/REPO:environment:production`. The `production` environment
has a required reviewer and its deployment branches are limited to `main`, so GitHub enforces both conditions
before it issues a token with that subject.

## Consequences

- Every AWS call from GitHub Actions goes through the reviewer gate. Jobs that only need a token for signing
  (`build` in `deploy.yml`, the Scorecard workflow) can hold `id-token: write` without being able to reach AWS.
- The environment's branch policy is now a security control, not a convenience. If someone removes the `main`
  restriction, a feature branch that declares `environment: production` would get the trusted subject after
  review. Setup step 2 in the README configures it, and the threat notes list the case.
- A future unattended deploy (no reviewer) needs its own environment without reviewers and its own subject in
  the list, decided in a new ADR.

## Compliance

Automated: `deploy_trust_accepts_exactly_the_production_environment` in `infra/tests/iam.tftest.hcl` asserts the
subject list equals `["repo:example-owner/example-repo:environment:production"]`, so adding the branch subject
back fails the `lint` workflow.

Manual: the `production` environment settings (required reviewer, deployment branches limited to `main`) live in
GitHub, not in this repository. The README lists them as a setup step.

## Notes

- Related: [ADR 0001](0001-exact-subject-matching.md), [ADR 0005](0005-build-once-deploy-by-digest.md).
- Only this ADR decides the branch-subject trade-off. Other documents link here instead of restating it.
