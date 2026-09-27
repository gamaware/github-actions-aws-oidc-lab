# ADR 0001: Match OIDC claims with StringEquals, never StringLike

## Status

Accepted

## Context

The deploy role trusts tokens from GitHub's OIDC issuer. Two claims decide which tokens STS accepts: `aud` (who
the token was minted for) and `sub` (which repository, branch, environment or event the job ran for). IAM lets the
trust policy match them exactly (`StringEquals`) or with patterns (`StringLike` with `*` and `?`).

Many published examples use `StringLike` with `repo:OWNER/*` or `repo:OWNER/REPO:*`. The first trusts every
repository the owner has now or creates later, including repositories created by anyone who gets write access to
the organization. The second trusts every branch, tag, pull request and environment of the repository. A missing
`aud` condition lets a token minted for another relying party be replayed against STS.

## Decision

The trust policy uses `StringEquals` only, for both claims:

- `aud` must be exactly `sts.amazonaws.com`.
- `sub` must be one of an explicit list of full subjects, built from the `github_owner`, `github_repo` and
  `github_environment` variables. The list has one entry today (see [ADR 0002](0002-environment-subject-only.md)).

Input validation on those three variables refuses wildcard and separator characters, so a typo such as `*` fails
at plan time instead of widening the trust policy.

## Consequences

- A new repository, branch or environment that needs to deploy must be added to the list on purpose, in a pull
  request that changes `infra/terraform/iam.tf`. That is the intended friction.
- The trust policy is easy to read and to test: there is nothing to expand.
- Reusing one role for many repositories is not possible without listing each one. The lab uses one role per
  deploy target instead ([ADR 0004](0004-one-role-per-deploy-target.md)).

## Compliance

Automated, in `terraform test` (`infra/terraform/tests/iam.tftest.hcl`, run by the `lint` workflow on every pull request):

- `deploy_trust_accepts_exactly_the_production_environment` asserts the only condition operator is
  `StringEquals`, the only keys are `aud` and `sub`, `aud` is `sts.amazonaws.com`, the subject list is exactly
  the production environment subject, and the rendered policy contains no `*` or `?`.
- `wildcard_owner_is_rejected`, `wildcard_repository_is_rejected` and `wildcard_environment_is_rejected` assert the
  variable validations refuse wildcards.

## Notes

- Threat cases for each claim: [docs/threat-notes.md](../threat-notes.md).
- GitHub can customize the `sub` claim template per repository. This lab keeps the default template; a custom one
  would change the subject strings and must be reflected in `local.trusted_subjects`.
