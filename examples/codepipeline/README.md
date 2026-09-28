# CodePipeline example: the same deploy with AWS CodePipeline and CodeBuild

The pipeline in [terraform/](terraform/) deploys the same app to the same ECS service as
[deploy.yml](../../.github/workflows/deploy.yml), with the build running in CodeBuild inside the account. The decision
and when to prefer each path are in [ADR 0010](../../docs/adr/0010-github-actions-vs-codepipeline.md).

![CodePipeline flow: source, CodeBuild test, scan and push, manual approval, ECS deploy, verify](../../docs/diagrams/codepipeline-flow.png)

| Stage | Action | What it does |
| --- | --- | --- |
| Source | CodeConnections (or S3) | reads `main` of the GitHub repository, or a zip in the artifact bucket |
| Build | CodeBuild, [buildspec-build.yml](buildspec-build.yml) | pytest, `docker build`, Trivy gate, push, export `IMAGE_URI` as `repository@sha256:...` |
| Approve | Manual approval | shows the digest; nothing reaches ECS until someone approves |
| Deploy | ECS deploy action | registers a revision with the image by digest and updates the service |
| Verify | CodeBuild, [buildspec-verify.yml](buildspec-verify.yml) | runs `scripts/verify-deployment.sh`: PRIMARY revision, rollout completed, healthy tasks |

## Access

Each principal has its own role, defined in [terraform/iam.tf](terraform/iam.tf):

- **Pipeline role** (`<name>-codepipeline`): reads and writes pipeline artifacts, uses the connection, starts the two
  CodeBuild projects, registers revisions of one task definition family, updates one service and passes only the task
  execution role to ECS. It cannot push to ECR.
- **Build role** (`<name>-codebuild-build`): reads and writes artifacts, writes its log group and pushes to one ECR
  repository. It cannot reach ECS or IAM.
- **Verify role** (`<name>-codebuild-verify`): reads the source artifact, writes its log group and reads the service
  and its tasks.

Every trust policy names the service principal with `aws:SourceAccount` and `aws:SourceArn` conditions for this
pipeline or project.

## Use it in an AWS account

1. Create the deploy target once with `infra/terraform`.
2. Create the pipeline:

   ```bash
   cd examples/codepipeline/terraform
   cp terraform.tfvars.example terraform.tfvars   # set github_repository and the ARNs from infra/terraform outputs
   terraform init
   terraform apply
   ```

3. Complete the GitHub connection once: in the console, Developer Tools, Settings, Connections, select the pending
   connection (`terraform output connection_arn`) and choose **Update pending connection**. Until then the Source
   stage fails.
4. Merge to `main`. The pipeline runs Build and stops at Approve. Approve in the console, or with
   `aws codepipeline put-approval-result`.

With `source_type = "s3"`, upload a zip of the repository root to `source/source.zip` in the artifact bucket
(`terraform output artifact_bucket`) and start the pipeline with `aws codepipeline start-pipeline-execution`.

## What is verified here

`make verify` runs `terraform test` on [terraform/tests/codepipeline.tftest.hcl](terraform/tests/codepipeline.tftest.hcl)
with a mocked provider, Checkov and tflint on the root, and
[tests/test_codepipeline_example.py](../../tests/test_codepipeline_example.py) on the buildspecs. None of them calls
AWS.

`make test-live-codepipeline` is manual. It applies a private live network, `infra/terraform` and this root to the
AWS CLI profile `dev` with an S3 source, runs the pipeline end to end, approves it, checks the three roles with the
IAM policy simulator, and destroys everything on exit. The task runs with no public IP in a VPC with no internet path,
and each plan passes a private-only pre-flight before it is applied ([docs/live-test.md](../../docs/live-test.md)).

## Limits

- No provenance or SBOM attestation, unlike the GitHub Actions path.
- The build project runs Docker in privileged mode, and its buildspec comes from the source: whoever can merge to
  `main` controls what runs with the build role.
- The base image comes from Docker Hub without credentials; Docker Hub rate limits apply. Mirror it through an ECR
  pull-through cache for regular use.
- The approval is a click by anyone allowed `codepipeline:PutApprovalResult` on the pipeline. Grant that permission
  to the approvers only.
