# Threat notes: what the trust conditions block

The deploy role's trust policy ([infra/policies/trust-policy.json.tftpl](../infra/policies/trust-policy.json.tftpl))
has two conditions, both `StringEquals`, so no wildcards:

| Claim | Required value |
| --- | --- |
| `aud` | `sts.amazonaws.com` |
| `sub` | `repo:OWNER/REPO:environment:production` or `repo:OWNER/REPO:ref:refs/heads/main` |

GitHub sets `sub` from the job's context, and the workflow cannot choose it. A job with an `environment` gets the
environment form. Any other job gets a `ref`, `pull_request` or tag form.

## Cases

| Attempt | Token `sub` | Result |
| --- | --- | --- |
| Deploy job on `main` with `environment: production` | `repo:OWNER/REPO:environment:production` | Allowed after the required reviewer approves |
| Workflow on a feature branch, no environment | `repo:OWNER/REPO:ref:refs/heads/feature-x` | Denied by STS |
| Workflow on a feature branch that declares `environment: production` | `repo:OWNER/REPO:environment:production` | Blocked by GitHub only if the environment's deployment branches are limited to `main` (setup step 2 in the README) |
| Pull request from a branch in this repository | `repo:OWNER/REPO:pull_request` | Denied by STS. `ci.yml` also has no `id-token: write` |
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

## The branch subject and a stricter option

The `ref:refs/heads/main` subject lets any job on `main` assume the role, even one that does not declare the
`production` environment and so skips the required reviewer. Branch protection on `main` limits who can add such a
job. For a stricter setup, remove the branch subject from `trusted_subjects` in [infra/iam.tf](../infra/iam.tf) and
keep only the environment subject. Then limit the `production` environment's deployment branches to `main`, so both
conditions are enforced by GitHub before a token with that subject exists.

## What the permission policy limits after a successful assume

- ECR writes only to one repository ARN. `ecr:GetAuthorizationToken` needs `*`, and it only returns a registry login.
- `ecs:UpdateService` and `ecs:DescribeServices` only on one service ARN.
- `ecs:RegisterTaskDefinition` only for the lab's task definition family. `ecs:DescribeTaskDefinition` does not
  support resource-level permissions, so it uses `*`; it is read-only.
- A new revision cannot add AWS permissions, because `iam:PassRole` allows only the task execution role, and only to
  `ecs-tasks.amazonaws.com`. A task definition that names any other role fails to register. Conditions also require
  Fargate compatibility and refuse privileged containers.
- `ecs:UpdateService` may only point the service at a revision of the same family and may not turn on ECS Exec.
- A revision can still run any image, command or user. The permission policy limits where the job deploys, not what
  it deploys; branch protection and the environment reviewer control that.
- No `iam:*` write actions, no `ecs:RunTask`, no access to other services.

## Residual risks

- Anyone who can merge to `main` and approve the `production` environment can deploy any image. Branch protection,
  CODEOWNERS and required reviewers carry that control.
- A compromised third-party action in the deploy job runs with the role's permissions for up to one hour. Actions are
  pinned to commit SHAs and Dependabot proposes updates, but the pinned code is still trusted code.
