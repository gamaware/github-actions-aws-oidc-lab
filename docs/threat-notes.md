# Threat notes: what the trust conditions block

The deploy role's trust policy
([infra/terraform/policies/trust-policy.json.tftpl](../infra/terraform/policies/trust-policy.json.tftpl)) has two
conditions, both `StringEquals`, so no wildcards:

| Claim | Required value |
| --- | --- |
| `aud` | `sts.amazonaws.com` |
| `sub` | `repo:OWNER/REPO:environment:production`, and nothing else |

GitHub sets `sub` from the job's context, and the workflow cannot choose it. A job with an `environment` gets the
environment form. Any other job gets a `ref`, `pull_request` or tag form.

## Cases

| Attempt | Token `sub` | Result |
| --- | --- | --- |
| Deploy job on `main` with `environment: production` | `repo:OWNER/REPO:environment:production` | Allowed after the required reviewer approves |
| Job on `main` without the environment, for example `build` in `deploy.yml` or the Scorecard job | `repo:OWNER/REPO:ref:refs/heads/main` | Denied by STS ([ADR 0002](adr/0002-environment-subject-only.md)) |
| Workflow on a feature branch, no environment | `repo:OWNER/REPO:ref:refs/heads/feature-x` | Denied by STS |
| Workflow on a feature branch that declares `environment: production` | `repo:OWNER/REPO:environment:production` | Blocked by GitHub only if the environment's deployment branches are limited to `main` (step 2 of the [deploy runbook](deploy-runbook.md)) |
| Pull request from a branch in this repository | `repo:OWNER/REPO:pull_request` | No pull request workflow here requests a token. Denied by the deploy role. Accepted by the read-only plan role only where a client installs the example plan workflow and sets `create_plan_role = true` (see below) |
| Pull request from a fork | `repo:OWNER/REPO:pull_request` | Denied by STS. On `pull_request`, GitHub gives fork PRs a read-only token and no `id-token: write`, unless a private repository enables sending write tokens to fork PR workflows |
| Job in a different repository, even the same owner | `repo:OWNER/OTHER:...` | Denied by STS |
| Tag push | `repo:OWNER/REPO:ref:refs/tags/v1` | Denied by STS |
| Job that uses a different environment, for example `staging` | `repo:OWNER/REPO:environment:staging` | Denied by STS |
| Token minted for another audience | `aud` is not `sts.amazonaws.com` | Denied by STS |

## Why the audience condition matters

Without the `aud` condition, a token GitHub issued for another relying party could be replayed against STS. Pinning
`aud` to `sts.amazonaws.com` means only tokens requested for AWS are accepted.

## Why StringEquals and not StringLike

A pattern such as `repo:OWNER/*` trusts every repository the owner has now and every one created later, including
repositories created by anyone who gets write access to the organization. This lab lists the exact subjects instead.

## Why there is no branch subject

The first version also trusted `repo:OWNER/REPO:ref:refs/heads/main`, which let a job on `main` skip the required
reviewer. [ADR 0002](adr/0002-environment-subject-only.md) records why it was removed and what depends on the
`production` environment's branch policy now.

## What the permission policy limits after a successful assume

- ECR writes only to one repository ARN. `ecr:GetAuthorizationToken` needs `*`, and it only returns a registry login.
- `ecs:UpdateService` and `ecs:DescribeServices` only on one service ARN.
- `ecs:ListTasks` only with the `ecs:cluster` condition set to the lab's cluster, and `ecs:DescribeTasks` only on
  tasks in that cluster. The verification step uses them to check the new tasks' health and image digest.
- `ecs:RegisterTaskDefinition` only for the lab's task definition family. `ecs:DescribeTaskDefinition` does not
  support resource-level permissions, so it uses `*`; it is read-only.
- A new revision cannot add AWS permissions, because `iam:PassRole` allows only the task execution role, and only to
  `ecs-tasks.amazonaws.com`. A task definition that names any other role fails to register. Conditions also require
  Fargate compatibility and refuse privileged containers.
- `ecs:UpdateService` may only point the service at a revision of the same family and may not turn on ECS Exec.
- A revision can still run any image, command or user. The permission policy limits where the job deploys, not what
  it deploys; branch protection and the environment reviewer control that.
- No `iam:*` write actions, no `ecs:RunTask`, no access to other services.

## The optional plan role

This repository does not run a pull request plan. `examples/workflows/plan.yml` is an example a client installs in
their own repository. With `create_plan_role = true`, a second role accepts exactly `repo:OWNER/REPO:pull_request`.
It can only call `Describe`, `Get` and `List` actions on this stack's resources and read one state object. Once the
example is installed, anyone who can open a pull request from a branch in that repository can read the stack's
configuration and state. Fork pull requests get no OIDC token. [ADR 0007](adr/0007-read-only-plan-role.md) records
the trade-off and [ADR 0011](adr/0011-plan-workflow-as-example.md) why the workflow is an example.

## Residual risks

- Anyone who can merge to `main` and approve the `production` environment can deploy any image. Branch protection,
  CODEOWNERS and required reviewers carry that control.
- The image that ships is scanned, attested and deployed by digest, but ECS does not check the attestation at run
  time; the pipeline does, before registering the task definition.
- A compromised third-party action in the deploy job runs with the role's permissions for up to one hour. Actions are
  pinned to commit SHAs and Dependabot proposes updates, but the pinned code is still trusted code.
