# ADR 0008: Test IAM policies offline with terraform test and a mocked provider

## Status

Accepted

## Context

The security of this lab is mostly in two JSON documents: the trust policy and the permission policy. Reading them
in review works once; it does not stop a later change from adding a subject, a wildcard or a new IAM action.

Online tests (apply to a sandbox account, try to assume the role from a feature branch, destroy) prove outcomes
but need an account, credentials in CI, and cleanup. Unit tests that restate the Terraform code prove nothing.

## Decision

Test the rendered policies, not the Terraform code, with `terraform test` and `mock_provider "aws"`:

- The policies are rendered with `templatefile`, so their JSON is computed by Terraform even when every AWS
  resource is mocked. Mocked resource ARNs are fixed in the test file so assertions can compare against them.
- Assertions state security properties: exactly these subjects, this audience, only `StringEquals`, no wildcard
  actions, Resource `*` only in named statements, `iam:PassRole` only for the execution role, the plan role
  read-only and off by default, and variable validations that refuse wildcards.
- The tests run in the `lint` workflow and locally with `terraform test` in `infra/`, with no AWS credentials.

## Consequences

- Policy regressions fail in seconds on every pull request, with no cloud access.
- The tests do not prove that AWS evaluates the policies as intended. The README's "Checks you can repeat" section
  lists the manual online checks (a feature-branch assume that must fail, CloudTrail evidence).
- Policies built with `aws_iam_policy_document` data sources are mocked, so their JSON is not real in these tests.
  That is why the two policies under test are templates.

## Compliance

`Terraform fmt, validate, test and tflint` is a required check. Each assertion's error message names the property
it protects.

## Notes

- Related: [ADR 0001](0001-exact-subject-matching.md), [ADR 0004](0004-one-role-per-deploy-target.md),
  [ADR 0007](0007-read-only-plan-role.md).
