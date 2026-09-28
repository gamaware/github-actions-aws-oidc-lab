# 0010. GitHub Actions vs CodePipeline: when to use each

## Status

Accepted

## Context

The lab deploys from GitHub Actions ([deploy.yml](../../.github/workflows/deploy.yml)) and shows the same deploy on
GitLab CI ([ADR 0009](0009-gitlab-ci-example.md)). Some clients run delivery inside AWS: their change process expects
AWS CodePipeline, their auditors read CloudTrail rather than CI logs, or their policy does not allow a third-party
runner to hold deploy credentials, even short-lived ones.

The two tools reach the same result by different means:

| Concern | GitHub Actions (this lab) | CodePipeline and CodeBuild |
| --- | --- | --- |
| Where builds run | GitHub-hosted runner, outside the account | CodeBuild in the account |
| How it gets AWS access | OIDC token exchanged for a one-hour role session | Service roles assumed by CodePipeline and CodeBuild |
| Trust boundary to review | Token subject and audience in a trust policy | Service principal plus `aws:SourceAccount` and `aws:SourceArn` |
| Approval | GitHub environment reviewer | Manual approval action, gated by `codepipeline:PutApprovalResult` |
| Deploy step | `amazon-ecs-deploy-task-definition` action | ECS deploy action with `imagedefinitions.json` |
| Audit trail | Workflow run logs, attestations | CloudTrail, pipeline execution history, CodeBuild logs in CloudWatch |
| Supply-chain evidence | Build provenance and SBOM attestations | Not built in; would need Signer or an external attestation step |
| Cost model | Runner minutes (free for public repositories) | Per action execution minute (V2) plus CodeBuild minutes |

Three options were considered:

1. GitHub Actions only, with CodePipeline mentioned in prose.
2. Replace the GitHub Actions deploy with CodePipeline.
3. Keep GitHub Actions as the implemented path and add CodePipeline as a second, tested path to the same ECS
   service, with its own roles.

## Decision

Option 3. `examples/codepipeline/` holds a Terraform root and two buildspecs:

- Source: a GitHub repository through AWS CodeConnections, or a zip in the artifact bucket for demos and the live
  test.
- Build: one CodeBuild project runs the unit tests, builds the image, fails on fixable HIGH or CRITICAL Trivy
  findings, pushes, and exports the image as `repository@sha256:<digest>`. Nothing that pushes runs in `post_build`,
  which CodeBuild runs even after a failed build phase.
- Approve: a manual approval that shows the digest.
- Deploy: the ECS deploy action updates the same service, by digest.
- Verify: a second CodeBuild project runs `scripts/verify-deployment.sh`, the same check the other paths use.

Each principal gets its own role: the pipeline role can start the two projects, use the connection and deploy to one
service; the build role can push to one repository and cannot reach ECS; the verify role only reads the service.
Every action is named in full. Artifacts and build logs are encrypted with a pipeline KMS key, and the artifact
bucket expires objects after 30 days.

When to use each, as advice for a client:

- **GitHub Actions with OIDC** when the code lives in GitHub, the team works in pull requests, and build provenance
  and SBOM attestations matter. Nothing to run in the account besides the role.
- **CodePipeline and CodeBuild** when builds must run inside the account (network access to private resources,
  data-residency rules), when the change record must live in AWS, or when the organization standardizes on AWS
  developer tools across teams and repositories hosted anywhere CodeConnections reaches.
- Both can coexist: GitHub Actions for pull request checks, CodePipeline for the deploy.

## Consequences

- The CI/CD offer covers both GitHub-native and AWS-native clients with tested code.
- Two deploy paths can update the same service. A client picks one per service; running both would let either
  deploy without the other's approval.
- The CodePipeline path does not attest provenance or an SBOM. Trivy runs on the image before the push, and the
  deploy uses the digest pushed by that build, but there is no signed statement a later check can verify.
- The CodeBuild build project runs Docker in privileged mode. Its buildspec comes from the pipeline source, so
  anyone who can merge to the source branch controls what runs with the build role. Branch protection on the
  repository is the boundary, as it is for GitHub Actions.
- A CodeConnections connection is created in `PENDING` state and needs one console handshake by an administrator;
  Terraform cannot complete it.
- The base image is pulled from Docker Hub without credentials, which is subject to Docker Hub rate limits shared
  across CodeBuild hosts. A client setup mirrors it through an ECR pull-through cache.

## Compliance

Automated, in `make verify`:

- `examples/codepipeline/terraform/tests/codepipeline.tftest.hcl` asserts the stage order (Source, Build, Approve,
  Deploy, Verify), the manual approval before the ECS deploy, the deploy input and configuration, KMS encryption of
  pipeline artifacts, the bucket and the logs, key rotation, the public access block, the lifecycle rule, the TLS-only
  bucket policy, no wildcard in any action of the three roles, `Resource "*"` only on the three API calls that need
  it, the exact action set of the pipeline and verify roles, no ECS or IAM access for the build role, and trust
  conditions on each role.
- `tests/test_codepipeline_example.py` asserts that every buildspec phase aborts on failure, nothing runs in
  `post_build`, Trivy is pinned and checksum-verified, tests and the Trivy gate run before the push, and the deploy
  receives the image by digest.
- Checkov scans `examples/codepipeline/terraform/` in `make verify` and in `security.yml`; its four skips are inline
  with their reasons.

Manual: `make test-live-codepipeline` applies the deploy target and the pipeline to a sandbox account, runs the
pipeline end to end with an S3 source, checks the three roles with the IAM policy simulator and destroys everything.

## Notes

- Deploy flow diagram: [docs/diagrams/codepipeline-flow.png](../diagrams/codepipeline-flow.png).
- The example's setup steps: [examples/codepipeline/README.md](../../examples/codepipeline/README.md).
