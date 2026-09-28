# Deploy runbook: run the lab in your own AWS account

This page takes the lab from a fork to a verified deploy in a sandbox account, then tears it down. The offline
checks in the [README](../README.md) need none of this.

## Deploy it

Prerequisites: Terraform 1.11 or later (CI pins the version in `infra/terraform/.terraform-version`), AWS
credentials for a sandbox account with IAM admin rights (only for this one-time setup), a VPC with subnets that can
reach ECR, and a copy of this repository under your own account.

1. **Create the infrastructure once.**

   ```bash
   cd infra/terraform
   cp terraform.tfvars.example terraform.tfvars   # set github_owner, github_repo, vpc_id, subnet_ids
   # Optional remote state: cp backend.tf.example backend.tf; cp backend.hcl.example backend.hcl; edit it
   terraform init              # or: terraform init -backend-config=backend.hcl
   terraform apply
   ```

   If the account already has the GitHub OIDC provider, set `create_oidc_provider = false`.

2. **Create the `production` environment** in the repository settings. Add a required reviewer and limit deployment
   branches to `main`. Both settings are part of the trust model ([ADR 0002](adr/0002-environment-subject-only.md)).

3. **Add repository variables** (Settings, Secrets and variables, Actions, Variables). None of them is a secret:

   | Variable | Value |
   | --- | --- |
   | `AWS_ROLE_ARN` | `terraform output -raw deploy_role_arn` |
   | `AWS_REGION` | the region you used, for example `us-east-1` |
   | `ECR_REPOSITORY_URL` | `terraform output -raw ecr_repository_url` |
   | `ECS_CLUSTER` | `terraform output -raw ecs_cluster` |
   | `ECS_SERVICE` | `terraform output -raw ecs_service` |
   | `ECS_TASK_FAMILY` | `terraform output -raw task_definition_family` |
   | `APP_URL` (optional) | base URL that reaches the service, for the HTTP part of the verification |

4. **Turn on the required checks** listed in the README's
   [security and quality gates](../README.md#security-and-quality-gates) with the command in
   [Repository settings](#repository-settings).

5. **Push to `main`.** Approve the deployment, then watch the build, push, deploy and verification steps. The
   service starts with `desired_count = 0`; set it to `1` and apply again once the first image exists.

6. **Optional: read-only plan on pull requests.** This repository does not run it; it ships as the example
   `examples/workflows/plan.yml`. In your own repository, use the S3 backend, set `create_plan_role = true` and
   `state_bucket`, apply, copy the example to `.github/workflows/plan.yml`, then add the variables
   `AWS_PLAN_ROLE_ARN` (`terraform output -raw plan_role_arn`), `TF_STATE_BUCKET`, and `TF_VARS_JSON` (your
   `terraform.tfvars` values as one JSON object). Pull requests that change `infra/terraform/` then show the plan in
   the job summary. Installing it gives same-repository pull requests an OIDC token that only the read-only plan
   role accepts ([ADR 0007](adr/0007-read-only-plan-role.md), [ADR 0011](adr/0011-plan-workflow-as-example.md)).

## Checks you can repeat

- **A job without the environment cannot assume the role.** Copy the credentials step into a workflow on `main` or
  any branch with no `environment` and run it. It fails with `Not authorized to perform
  sts:AssumeRoleWithWebIdentity`, because the token's subject is `repo:OWNER/REPO:ref:refs/heads/<branch>`.
- **A pull request cannot obtain AWS credentials.** No pull request workflow in `.github/workflows/` has
  `id-token: write`, and `tests/test_workflows.py` fails if one does. If a client installs the example
  `plan.yml`, its token carries the `pull_request` subject, which the deploy role refuses and only the read-only
  plan role accepts. Fork pull requests get no token at all.
- **The deployed image is the attested one.** Take the digest from the deploy job summary and run
  `gh attestation verify oci://YOUR_ECR_REPOSITORY_URL@sha256:DIGEST --repo OWNER/REPO`.
- **The federated session is visible in CloudTrail.** Look up `AssumeRoleWithWebIdentity` events. The event shows
  `userIdentity.type: WebIdentityUser`, the provider `token.actions.githubusercontent.com`, the subject, and the
  session name `gha-<run_id>-<attempt>`, which links it to one workflow run.

  ```bash
  aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
    --max-results 5
  ```

## Repository settings

Branch protection on `main` requires the checks in the README's gates table and one approving review from a code
owner. Apply it with:

```bash
gh api --method PUT repos/OWNER/REPO/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "verify",
      "lint-docs / markdownlint", "lint-docs / links", "lint-docs / vale",
      "lint-actions / actionlint", "lint-actions / zizmor", "secrets / gitleaks",
      "container / hadolint", "container / build-scan", "security / trivy",
      "Semgrep (code)", "Trivy (image)", "Checkov (infra)"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "required_conversation_resolution": true,
  "required_linear_history": true,
  "restrictions": null
}
EOF
```

If you install the example `plan.yml`, do not make `Terraform plan (read-only)` a required check: it is skipped
when the plan role is not configured and for fork pull requests.

`update-pre-commit-hooks.yml` opens a weekly pull request with new hook versions. It reads the `PRE_COMMIT_PAT`
secret (a fine-grained token with contents and pull request write access to this repository) from an environment
named `automation`. Limit that environment's deployment branches to `main`, so a workflow changed on another branch
cannot read the token.

## Cost and teardown

The costs are the Fargate task while it runs, ECR storage for at most 10 images (a lifecycle rule expires the rest),
CloudWatch Logs and Container Insights, and one customer managed KMS key for the logs (about 1 USD per month). The
GitHub side is free for public repositories. Scale the service to zero tasks between demos:

```bash
terraform apply -var desired_count=0
```

`terraform destroy` removes everything, including images in the repository (`ecr_force_delete` defaults to `true`;
set it to `false` outside a sandbox).
The KMS key is deleted after its 7-day waiting period. A state bucket created for the backend is not part of this
stack; delete it separately.

## Automated live check

`make test-live` does a smaller version of this runbook without GitHub: it applies a private live network and both
Terraform roots to the AWS CLI profile `dev` (override with `AWS_PROFILE_LIVE`), asks the IAM policy simulator
whether each deploy role can push to its repository, update its service and pass only the execution role to ECS, and
cannot do the same next to them. It destroys both stacks and the network on exit, even after a failure, and fails
if anything tagged `purpose=portfolio-test` remains. It shows the caller identity and asks for confirmation before
creating anything. Its output is never committed.

`make test-live-codepipeline` covers the CodePipeline path the same way: it applies the private live network with
VPC endpoints, `infra/terraform` (one task, no public IP, no inbound rule) and `examples/codepipeline/terraform` with
an S3 source, uploads `git archive HEAD`,
runs the pipeline, approves it, waits for Deploy and Verify, checks the pipeline, build and verify roles with the
IAM policy simulator, then deregisters the revisions the pipeline registered and destroys both stacks and the network.
It takes about 15 minutes and builds only committed files.

Both run private-only: a dedicated VPC with no internet or NAT gateway, no public IPs, no inbound rule from the
internet, and a pre-flight that checks each Terraform plan with `scripts/check_private_plan.py` before it is applied.
See [live-test.md](live-test.md).

## Variants

The same pattern (one OIDC provider, one role per deploy target, a subject pinned to a repository and environment)
works for other targets:

- **AWS Lambda:** replace the ECR and ECS statements with `lambda:UpdateFunctionCode` and
  `lambda:PublishVersion` on one function ARN.
- **S3 static hosting:** allow `s3:PutObject` and `s3:DeleteObject` on one bucket prefix and
  `cloudfront:CreateInvalidation` on one distribution.
- **GitLab CI:** implemented and tested in [examples/gitlab-ci](../examples/gitlab-ci/README.md)
  ([ADR 0009](adr/0009-gitlab-ci-example.md)).
- **AWS CodePipeline and CodeBuild:** implemented and tested in
  [examples/codepipeline](../examples/codepipeline/README.md)
  ([ADR 0010](adr/0010-github-actions-vs-codepipeline.md)).
- **Jenkins:** a documented pattern in [jenkins-pattern.md](jenkins-pattern.md).
