# ADR 0003: No ECS task role; the execution role only pulls and logs

## Status

Accepted

## Context

An ECS task can have two roles. The execution role is used by the ECS agent to pull the image from ECR and write
container logs. The task role is what the application code gets as AWS credentials at runtime.

The service in this lab is a small HTTP server that uses only the Python standard library and calls no AWS API.
Templates often attach a task role anyway, sometimes with broad managed policies, "for later".

The deploy role must be able to pass a role to ECS when it registers a task definition. Whatever it may pass is,
in effect, what any deployed image can do.

## Decision

- The task definition has no task role.
- The execution role has three statements: `ecr:GetAuthorizationToken`, image pulls from the one ECR repository,
  and `logs:CreateLogStream` and `logs:PutLogEvents` on the one log group.
- The deploy role's `iam:PassRole` is limited to the execution role, and only to `ecs-tasks.amazonaws.com`.

## Consequences

- A compromised container has no AWS credentials to steal from the task metadata endpoint.
- A pull request cannot quietly give the app AWS access by adding `taskRoleArn` to the task definition: the deploy
  role cannot pass any other role, so the registration fails.
- An app that needs AWS access later needs a new role, a change to the PassRole statement, and a new ADR.

## Compliance

Automated, in `infra/terraform/tests/iam.tftest.hcl` (`deploy_permissions_have_no_wildcard_actions_and_few_wildcard_resources`):

- `iam:PassRole` is the only IAM action in the deploy policy.
- Its resource is exactly the execution role ARN and its `iam:PassedToService` condition is
  `ecs-tasks.amazonaws.com`.

Checkov (`Checkov (infra)` required check) scans the execution role policy on every pull request.

## Notes

- Related: [ADR 0004](0004-one-role-per-deploy-target.md).
