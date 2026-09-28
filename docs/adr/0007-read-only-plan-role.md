# 0007. A separate, optional, read-only role for terraform plan on pull requests

## Status

Accepted

## Context

A reviewer of a pull request that changes `infra/terraform/` should see what `terraform plan` would do against the real
account. That needs AWS credentials in a pull request workflow, which the first version avoided entirely: no
pull request job had `id-token: write`.

A pull request author controls the workflow file and the Terraform code their pull request runs. Anything the plan
job's credentials can do, the author can do, for example with an `external` data source.

## Decision

- Add an optional role, `<name>-github-plan`, created only when `create_plan_role = true`.
- Its trust policy accepts exactly `repo:OWNER/REPO:pull_request` with `aud` `sts.amazonaws.com`, using
  `StringEquals` ([ADR 0001](0001-exact-subject-matching.md)).
- Its permissions are only `Describe`, `Get` and `List` actions: the state object and bucket listing, this stack's
  roles and OIDC provider, the ECR repository, the ECS cluster and service, the KMS key, the log group, and a few
  describe calls that have no resource-level permissions. No `s3:PutObject`, so the plan runs with `-lock=false`.
- The `plan` workflow ships as a client-installed example, `examples/workflows/plan.yml`, not as an active
  workflow here ([ADR 0011](0011-plan-workflow-as-example.md)). Once installed, it runs only for pull requests
  from the same repository (fork pull requests get no OIDC token), only when `infra/terraform/` changes, and only
  when the `AWS_PLAN_ROLE_ARN` variable is set. It writes the plan
  to the job summary, not to a pull request comment, so it needs no `pull-requests: write`.
- Applies stay out of CI and run from a workstation with the state lock.

## Consequences

- Reviewers see the real plan. A pull request author can read the state and the lab's resource configuration.
  The state holds no secrets in this stack; a stack whose state does hold secrets should not use this pattern.
- Some describe calls have no resource-level permissions. `ecs:DescribeTaskDefinition` on `*` lets the role read
  every task definition in the account and region, including plaintext environment values of other stacks. Use
  the plan role only in an account dedicated to this lab, and keep secrets out of task definition environments.
- Where a client installs the example, same-repository pull requests can hold an OIDC token. The plan role is the
  only role that accepts it; the deploy role still refuses the `pull_request` subject. In this repository no pull
  request workflow requests a token.
- If the provider starts calling a read action the policy does not list, the plan fails with AccessDenied. It
  fails closed; add the action.
- The plan is best-effort review evidence, not what gets applied. The apply re-plans.

## Compliance

Automated, in `infra/terraform/tests/iam.tftest.hcl`:

- `plan_role_trusts_only_pull_requests_and_can_only_read` asserts `StringEquals` only, `aud` `sts.amazonaws.com`,
  the subject list exactly `["repo:example-owner/example-repo:pull_request"]`, no wildcards in the trust policy,
  every action matching `service:(Describe|Get|List)Name`, and the state read limited to one object.
- `deploy_permissions_have_no_wildcard_actions_and_few_wildcard_resources` asserts the role is off by default.
- `plan_role_without_state_bucket_is_rejected` asserts the role cannot be created without a state bucket.

## Notes

- [ADR 0011](0011-plan-workflow-as-example.md) moved the workflow from `.github/workflows/` to
  `examples/workflows/`. The role, its trust policy and its permissions are unchanged.

- Backend example: `infra/terraform/backend.tf.example` and `infra/terraform/backend.hcl.example`.
- The plan role in `terraform-aws-rescue-lab` makes the opposite choice and may write lock files. There, an engineer
  applies by hand during a state migration, so a plan that takes the lock fails fast instead of reading state in the
  middle of an apply. Here, applies run from one workstation with the lock, and a pull request plan is review
  evidence, so skipping the lock keeps the role read-only.
