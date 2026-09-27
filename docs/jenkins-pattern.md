# Jenkins: the same deploy without stored keys

This lab does not ship a Jenkins pipeline. This page records the pattern a Jenkins deployment follows, so a Jenkins
team can map each control in the GitHub and GitLab versions to its own setup. Nothing here is tested by
`make verify`.

## The problem Jenkins adds

GitHub Actions and GitLab CI sign an OIDC token for each job, and the token says which repository, branch or
environment the job ran for. Jenkins core has no such issuer. Without one, teams tend to store an access key as a
Jenkins credential, which is exactly what the lab removes.

## Two ways to keep keys out of Jenkins

| Approach | How the job gets credentials | What scopes the deploy role |
| --- | --- | --- |
| Agent identity | The agent runs on EC2 with an instance profile, or on EKS with EKS Pod Identity or IAM roles for service accounts. The deploy stage calls `sts:AssumeRole` into the deploy role. | The deploy role trusts only the agent role. Only the deploy agent pool carries that role; other jobs run on agents without it. |
| OIDC from Jenkins | An OIDC provider plugin makes the controller an issuer and exposes an ID token credential to the job. The job calls `sts:AssumeRoleWithWebIdentity`, as in the lab. | The trust policy matches `aud` and `sub` with `StringEquals`, as in [ADR 0001](adr/0001-exact-subject-matching.md). The subject names the job, not a branch or environment, so folder and job permissions become the boundary. |

In both cases the permission policy is the same one the lab uses
([deploy-policy.json.tftpl](../infra/terraform/policies/deploy-policy.json.tftpl)): one ECR repository, one ECS
service, one execution role to pass.

## Mapping the lab's controls

| Lab control | GitHub Actions | GitLab CI | Jenkins |
| --- | --- | --- | --- |
| No stored AWS keys | OIDC token per job | `id_tokens` per job | Agent role, or an OIDC plugin |
| Only the deploy step reaches AWS | Environment subject ([ADR 0002](adr/0002-environment-subject-only.md)) | Only the deploy job declares `id_tokens` ([ADR 0009](adr/0009-gitlab-ci-example.md)) | Dedicated agent label, or a job-scoped subject |
| Human approval before deploy | Required reviewer on `production` | Protected environment (paid tiers) or `when: manual` | `input` step limited to a group |
| Build once, deploy by digest | OCI archive, `skopeo --preserve-digests` | Same | Same commands in a `sh` step |
| Verify the rollout | `scripts/verify-deployment.sh` | Same script | Same script |

## Limits

- The controller holds the signing key or the agent roles. A compromised controller can mint tokens or run jobs on
  the deploy agents, so it is part of the trust boundary in a way GitHub's and GitLab's issuers are not.
- Plugin names, versions and token claims change between Jenkins releases. Pin the plugin version and test the
  trust policy against a real token before relying on it.
