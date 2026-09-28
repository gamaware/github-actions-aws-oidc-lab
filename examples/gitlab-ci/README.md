# GitLab CI example: the same deploy with GitLab OIDC

The pipeline in [.gitlab-ci.yml](.gitlab-ci.yml) deploys the same app to the same ECS service as
[deploy.yml](../../.github/workflows/deploy.yml), from GitLab CI, with no AWS keys stored in CI/CD variables. The
decision and its trade-offs are in [ADR 0009](../../docs/adr/0009-gitlab-ci-example.md).

| Stage | Job | What it does |
| --- | --- | --- |
| test | `unit-tests` | pytest on `app/`, no AWS access |
| build | `build-image` | builds the image once as an OCI archive, records its digest |
| scan | `scan-image` | Trivy gate: fixable HIGH and CRITICAL findings fail the pipeline |
| deploy | `deploy-production` | manual, `main` only: ID token, OIDC role, push by digest, ECS deploy, verification |

## How the deploy job gets AWS credentials

1. The job declares `id_tokens` with `aud: sts.amazonaws.com`. GitLab signs a JWT whose `sub` is
   `project_path:GROUP/PROJECT:ref_type:branch:ref:main`.
2. The job writes the token to a temporary file and sets `AWS_WEB_IDENTITY_TOKEN_FILE` and
   `AWS_ROLE_SESSION_NAME`. With the `AWS_ROLE_ARN` project variable, the AWS CLI calls
   `sts:AssumeRoleWithWebIdentity` on its own.
3. STS checks the token against the GitLab OIDC provider and the role's trust policy: `StringEquals` on `aud` and
   `sub`, one subject, no wildcards.

No other job declares `id_tokens`, so no other job receives a token.

## Use it in a GitLab project

1. Copy the repository into a GitLab project and move `examples/gitlab-ci/.gitlab-ci.yml` to the project root. The
   jobs expect `app/` and `scripts/` at the root.
2. Protect the `main` branch. On paid tiers, also protect the `production` environment with a required approval.
3. Create the deploy target once with `infra/terraform` (the GitHub role can stay or be removed).
4. Create the GitLab role:

   ```bash
   cd examples/gitlab-ci/terraform
   cp terraform.tfvars.example terraform.tfvars   # set gitlab_project_path and the ARNs from infra/terraform outputs
   terraform init
   terraform apply
   ```

   Set `create_oidc_provider = false` if the account already has a provider for the same GitLab URL.

5. Add the project CI/CD variables `AWS_ROLE_ARN` (`terraform output -raw deploy_role_arn`), `AWS_REGION`,
   `ECR_REPOSITORY_URL`, `ECS_CLUSTER`, `ECS_SERVICE`, `ECS_TASK_FAMILY` and optionally `APP_URL`. None is a secret.

## What is verified here

`make verify` runs `terraform test` on [terraform/tests/gitlab.tftest.hcl](terraform/tests/gitlab.tftest.hcl) with a
mocked provider and [tests/test_gitlab_example.py](../../tests/test_gitlab_example.py) on the pipeline file. Neither
runs GitLab or calls AWS.

## Limits

- The subject names the branch, not the environment. Any job on `main` that declares `id_tokens` with this
  audience could assume the role; the pipeline test fails if a second job does.
- The subject names the branch by name, not by protection status. A merge request from a fork whose source branch
  is also called `main` could, if a maintainer runs its pipeline in the parent project, run the fork's own
  `.gitlab-ci.yml` with an `id_tokens` job. Do not run fork merge request pipelines in the parent project; the
  branch name alone does not stop a fork that picks the same name.
- On the free tier, `when: manual` is a click, not an approval.
- The deploy job installs `awscli2` and `jq` from the Fedora repositories at run time. A production pipeline would
  use a prebuilt, digest-pinned image with both.
