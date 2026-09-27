# GitHub Actions to AWS with OIDC, a least-privilege role and security gates

Deploy a container to Amazon ECS on Fargate from CI with no stored AWS keys, a role that reaches one service, and
gates that stop an unscanned image. GitHub Actions end to end, with the same deploy on GitLab CI as a tested example.

[![ci](https://github.com/gamaware/github-actions-aws-oidc-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/gamaware/github-actions-aws-oidc-lab/actions/workflows/ci.yml)
[![security](https://github.com/gamaware/github-actions-aws-oidc-lab/actions/workflows/security.yml/badge.svg)](https://github.com/gamaware/github-actions-aws-oidc-lab/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Lab](https://img.shields.io/badge/type-lab-lightgrey.svg)

![CI/CD deployment pipeline to AWS with GitHub Actions, GitLab or Jenkins](docs/assets/cover.png)

> **Lab.** "Harbor Goods" is a fictional client. Account IDs are AWS documentation examples (`111122223333`).

## What this proves

- **No long-lived AWS keys in CI.** The deploy job trades a short-lived OIDC token for one-hour role credentials.
  The trust policy accepts one subject and one audience, with `StringEquals` only.
- **A role that reaches one service.** It can push to one ECR repository, update one ECS service and pass one
  execution role, and nothing else. Offline tests assert this, and `make test-live` asks the IAM policy simulator.
- **The deployed image is the scanned image.** It is built once, gated by Trivy, attested, pushed with its digest
  preserved and deployed as `image@sha256`. A post-deploy check fails the run if the circuit breaker rolled back.
- **Pull requests cannot deploy.** The deploy role refuses the `pull_request` subject, and no pull request workflow
  can request an `id-token` except the optional read-only plan.
- **The same pattern on GitLab CI.** `examples/gitlab-ci/` deploys the same image to the same service through
  GitLab's OIDC tokens, with its own tests. Jenkins is covered as a documented pattern.

## Inspect the deliverable

| Artifact | What to look at |
| --- | --- |
| [deploy.yml](.github/workflows/deploy.yml) | Build once, Trivy gate, attestations, OIDC, push by digest, deploy, verify |
| [trust-policy.json.tftpl](infra/terraform/policies/trust-policy.json.tftpl) | The single trusted subject and audience |
| [deploy-policy.json.tftpl](infra/terraform/policies/deploy-policy.json.tftpl) | One repository, one service, one role to pass |
| [iam.tftest.hcl](infra/terraform/tests/iam.tftest.hcl) | Offline assertions on both policies, wildcards refused |
| [verify-deployment.sh](scripts/verify-deployment.sh) | The post-deploy check that catches a circuit-breaker rollback |
| [examples/gitlab-ci](examples/gitlab-ci/README.md) | The GitLab CI pipeline, its role and tests |
| [threat-notes.md](docs/threat-notes.md) | Each token subject and whether STS accepts it |
| [deploy-runbook.md](docs/deploy-runbook.md) | Deploying the lab to a sandbox account, cost and teardown |

## Scenario and acceptance criteria

Harbor Goods, a fictional mid-size retailer, deploys a small storefront service to ECS on Fargate. Today a CI secret
holds an IAM user's access key with broad permissions, and a pull request from any branch can run a job that uses
it. The team uses GitHub for the storefront and GitLab for two internal tools, and wants one pattern for both.

The work is done when:

1. No workflow or pipeline stores an AWS access key; `tests/test_gitlab_example.py` and a repository search find none.
2. The deploy role trusts exactly `repo:OWNER/REPO:environment:production` (GitHub) or the protected `main` branch
   subject (GitLab), with audience `sts.amazonaws.com`; `terraform test` asserts both.
3. The role's actions are named in full and scoped to one repository, service and execution role; `terraform test`
   asserts it offline and `make test-live` checks it with the IAM policy simulator.
4. A pull request cannot obtain AWS credentials; `tests/test_workflows.py` fails if any pull request workflow other
   than the optional read-only plan asks for an `id-token`.
5. The deployed digest equals the scanned digest, and a rollback fails the run.
6. `make verify` passes offline in under a minute.

## Architecture

![Keyless deploys from CI to AWS: GitHub Actions and GitLab CI trade OIDC tokens for role credentials](docs/diagrams/context.png)

The engineer merges to `main` and approves the production deploy. The CI job asks its own OIDC issuer for a signed
token, and AWS STS exchanges it for one-hour credentials after checking the deploy role's trust policy. With those
credentials the job pushes the scanned image to Amazon ECR by digest and updates the Amazon ECS service, then verifies
the rollout. GitHub Actions is the implemented path; GitLab CI (dashed) is the tested example.

The deployment view shows the seven steps of `deploy.yml`, the approval gate and the pull request path that STS
refuses: [docs/diagrams/deploy-flow.png](docs/diagrams/deploy-flow.png). Diagram sources are the `.drawio` files next
to the images.

## Verify locally

Prerequisites, with the versions CI uses: Python 3.13 with [uv](https://docs.astral.sh/uv/), Terraform 1.16.4 (from
`infra/terraform/.terraform-version`; 1.9 or later works), tflint 0.61.0, shellharden 4.3.2, hadolint 2.15.1, and
shellcheck (CI uses the runner's; 0.11.0 locally). No AWS account or credentials.

```bash
make verify
```

Expected output ends with:

```text
Success! 7 passed, 0 failed.
Success! 7 passed, 0 failed.
...
No findings to report. Good job! (8 suppressed)
make verify: all checks passed
```

It takes about 25 seconds once tools and providers are cached. It runs pytest (45 tests), ruff, `terraform fmt`,
`validate`, mocked `terraform test` and tflint on both Terraform roots, Checkov, shellcheck, shellharden, hadolint,
actionlint and zizmor. `make image` adds the Trivy image gate (needs Docker) and `make semgrep` the Semgrep rulesets.

`make test-live` is optional and manual. It applies both Terraform roots to a sandbox account, checks the roles with
the IAM policy simulator and always destroys what it created; see
[deploy-runbook.md](docs/deploy-runbook.md#automated-live-check). To deploy the lab end to end from your own fork,
follow the same runbook.

## Repository map

```text
app/                       Python standard-library HTTP service, its tests, Dockerfile pinned by digest
infra/terraform/           OIDC provider, deploy role, optional read-only plan role, ECR, ECS on Fargate
infra/terraform/policies/  trust and permission policies as JSON templates
infra/terraform/tests/     terraform test with a mocked provider
examples/gitlab-ci/        .gitlab-ci.yml and a Terraform root for the GitLab OIDC role, with tests
tests/                     pytest: workflow hardening rules and GitLab pipeline properties
scripts/                   verify-deployment.sh (both pipelines), test-live.sh (manual, real AWS)
.github/workflows/         ci (make verify + shared checks), security (SARIF gates), deploy, plan, scorecard,
                           update-pre-commit-hooks
docs/adr/                  architecture decision records
docs/diagrams/             context and deployment diagrams (.drawio source, .png export)
docs/                      threat notes, deploy runbook, Jenkins pattern
```

## Decisions and trade-offs

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](docs/adr/0001-exact-subject-matching.md) | Match OIDC claims with StringEquals, never StringLike | Accepted |
| [0002](docs/adr/0002-environment-subject-only.md) | Trust only the environment subject, not the branch subject | Accepted |
| [0003](docs/adr/0003-no-task-role.md) | No ECS task role; the execution role only pulls and logs | Accepted |
| [0004](docs/adr/0004-one-role-per-deploy-target.md) | One OIDC role per deploy target | Accepted |
| [0005](docs/adr/0005-build-once-deploy-by-digest.md) | Build once, scan what ships, deploy by digest, verify after | Accepted |
| [0006](docs/adr/0006-security-gates.md) | Semgrep, Trivy and Checkov as required checks, with SARIF in code scanning | Accepted |
| [0007](docs/adr/0007-read-only-plan-role.md) | A separate, optional, read-only role for terraform plan on pull requests | Accepted |
| [0008](docs/adr/0008-offline-policy-tests.md) | Test IAM policies offline with terraform test and a mocked provider | Accepted |
| [0009](docs/adr/0009-gitlab-ci-example.md) | Show the GitLab CI equivalent as a tested example, bound to the protected branch | Accepted |

## Security and quality gates

| Gate | Where | Why |
| --- | --- | --- |
| `make verify` | `ci.yml` | Same command as locally: tests, Terraform tests, linters, Checkov, workflow scanners |
| markdownlint, lychee, Vale | `ci.yml`, shared `lint-docs` | Docs stay readable and links stay alive |
| actionlint, zizmor | `ci.yml`, shared `lint-actions` | Workflow syntax and known-bad patterns |
| gitleaks | `ci.yml`, shared `secrets` | No credentials in history |
| hadolint, image build and Trivy | `ci.yml`, shared `container` | Dockerfile rules and image vulnerabilities |
| Trivy on the repository | `ci.yml`, shared `security` | Vulnerabilities, secrets and IaC misconfigurations |
| Semgrep, Trivy image, Checkov | `security.yml` | Required gates with SARIF in code scanning ([ADR 0006](docs/adr/0006-security-gates.md)) |
| OpenSSF Scorecard | `scorecard.yml` | The repository's own supply-chain practices |

Every workflow starts from `permissions: {}` and grants per job; actions are pinned to full commit SHAs (the
shared reusable workflows are the one exception, see the limits below), and there is no `pull_request_target`.
Pre-commit runs the same hygiene locally, plus detect-secrets and conventional commit messages.
The required check names and the branch protection command are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Limits and production adaptations

- **CI never touches AWS.** The policies are tested offline with a mocked provider
  ([ADR 0008](docs/adr/0008-offline-policy-tests.md)); that proves what the JSON says. `make test-live` checks how IAM
  evaluates it, but runs only by hand.
- **The GitLab pipeline is not run here.** Its tests prove what the files say. GitLab's subject names the branch,
  not the environment, and on the free tier `when: manual` is a click, not an approval
  ([ADR 0009](docs/adr/0009-gitlab-ci-example.md)).
- **Jenkins is covered by a documented pattern** ([docs/jenkins-pattern.md](docs/jenkins-pattern.md)), with no
  pipeline code or tests.
- **Some controls live in GitHub settings:** the `production` environment's reviewer and branch policy, and branch
  protection with the required checks. The repository documents them; it cannot enforce them.
- **The permission policy limits where the job deploys, not what.** Anyone who can merge to `main` and approve
  `production` can ship any image that passes the gates.
- **Attestations are verified by the pipeline, not by ECS.** Someone with console access could register a task
  definition with an unverified image.
- **One environment, one account.** A real engagement adds staging in its own account with its own role and subject,
  a load balancer, and VPC endpoints for ECR, S3 and CloudWatch Logs so task egress no longer needs the internet.
- **The optional plan role can read state** for same-repository pull requests. That is acceptable for this stack and
  would not be for a stack whose state holds secrets ([ADR 0007](docs/adr/0007-read-only-plan-role.md)).
- **Shared workflows are called by branch** until the re-pin pass pins them to a reviewed commit.

## Related work

- [AWS DevOps portfolio](https://github.com/gamaware/aws-devops-portfolio): the index of every lab and sample
  deliverable.
- Upwork service: "CI/CD deployment pipeline to AWS with GitHub Actions, GitLab or Jenkins". This lab is the
  pattern that service delivers on a client's own repository and account.
- The method is the one Alex uses in audits for ITESO and freelance clients in Guadalajara.

## License

[MIT](LICENSE)
