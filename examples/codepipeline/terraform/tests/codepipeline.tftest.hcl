# Offline tests for the CodePipeline and CodeBuild path. The AWS provider is
# mocked, so no credentials are needed and nothing is created. Policies are
# built with jsonencode, so the JSON asserted here is the JSON AWS would get.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::oidc-lab-pipeline-example"
      bucket = "oidc-lab-pipeline-example"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:/aws/codebuild/oidc-lab"
    }
  }

  mock_resource "aws_codebuild_project" {
    defaults = {
      arn = "arn:aws:codebuild:us-east-1:111122223333:project/oidc-lab"
    }
  }

  mock_resource "aws_codeconnections_connection" {
    defaults = {
      arn = "arn:aws:codeconnections:us-east-1:111122223333:connection/aEXAMPLE-8aad-4d5d-8878-dfcab0bc441f"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/oidc-lab-codepipeline"
    }
  }
}

variables {
  github_repository      = "harbor-goods/storefront"
  ecr_repository_arn     = "arn:aws:ecr:us-east-1:111122223333:repository/oidc-lab"
  ecs_cluster_arn        = "arn:aws:ecs:us-east-1:111122223333:cluster/oidc-lab"
  ecs_service_arn        = "arn:aws:ecs:us-east-1:111122223333:service/oidc-lab/oidc-lab"
  execution_role_arn     = "arn:aws:iam::111122223333:role/oidc-lab-task-execution"
  task_definition_family = "oidc-lab"
}

run "stages_run_in_order_with_approval_before_deploy" {
  command = apply

  assert {
    condition     = [for s in aws_codepipeline.this.stage : s.name] == ["Source", "Build", "Approve", "Deploy", "Verify"]
    error_message = "The pipeline must run Source, Build, Approve, Deploy and Verify, in that order."
  }

  assert {
    condition     = index([for s in aws_codepipeline.this.stage : s.name], "Approve") < index([for s in aws_codepipeline.this.stage : s.name], "Deploy")
    error_message = "The manual approval must come before the deploy."
  }

  assert {
    condition     = aws_codepipeline.this.stage[2].action[0].category == "Approval" && aws_codepipeline.this.stage[2].action[0].provider == "Manual"
    error_message = "The Approve stage must be a manual approval."
  }

  assert {
    condition     = length(flatten([for s in aws_codepipeline.this.stage : [for a in s.action : a if a.category == "Deploy"]])) == 1 && aws_codepipeline.this.stage[3].action[0].category == "Deploy"
    error_message = "The ECS deploy must be the only Deploy action, in the Deploy stage."
  }

  assert {
    condition     = aws_codepipeline.this.pipeline_type == "V2" && aws_codepipeline.this.execution_mode == "QUEUED"
    error_message = "The pipeline must be V2 and queue executions, so rollouts never overlap."
  }
}

run "build_pushes_and_deploy_uses_the_ecs_action" {
  command = apply

  assert {
    condition     = aws_codepipeline.this.stage[1].action[0].provider == "CodeBuild" && aws_codepipeline.this.stage[1].action[0].namespace == "BuildVariables"
    error_message = "The Build stage must run CodeBuild and export its variables as BuildVariables."
  }

  assert {
    condition     = aws_codebuild_project.build.source[0].buildspec == "examples/codepipeline/buildspec-build.yml" && aws_codebuild_project.verify.source[0].buildspec == "examples/codepipeline/buildspec-verify.yml"
    error_message = "Each project must run its buildspec from the repository."
  }

  assert {
    condition     = aws_codebuild_project.build.environment[0].environment_variable[0].value == "111122223333.dkr.ecr.us-east-1.amazonaws.com/oidc-lab"
    error_message = "The build must push to the repository from ecr_repository_arn."
  }

  assert {
    condition = aws_codepipeline.this.stage[3].action[0].provider == "ECS" && aws_codepipeline.this.stage[3].action[0].configuration == tomap({
      ClusterName       = "oidc-lab"
      ServiceName       = "oidc-lab"
      FileName          = "imagedefinitions.json"
      DeploymentTimeout = "15"
    })
    error_message = "The deploy must be the ECS action on the lab's cluster and service, from imagedefinitions.json."
  }

  assert {
    condition     = aws_codepipeline.this.stage[3].action[0].input_artifacts == tolist(["BuildOutput"])
    error_message = "The deploy must read the build output, which names the image by digest."
  }

  assert {
    condition     = jsondecode(aws_codepipeline.this.stage[4].action[0].configuration.EnvironmentVariables)[0].value == "#{BuildVariables.IMAGE_URI}"
    error_message = "The Verify stage must check the image URI the Build stage pushed."
  }

  assert {
    condition     = aws_codebuild_project.build.environment[0].privileged_mode && !aws_codebuild_project.verify.environment[0].privileged_mode
    error_message = "Only the build project, which runs docker build, may be privileged."
  }
}

run "artifacts_and_logs_are_encrypted_and_expire" {
  command = apply

  assert {
    condition = alltrue([
      for store in aws_codepipeline.this.artifact_store :
      store.type == "S3" && store.encryption_key[0].type == "KMS" && store.encryption_key[0].id == aws_kms_key.pipeline.arn
    ]) && length(aws_codepipeline.this.artifact_store) == 1
    error_message = "Pipeline artifacts must be encrypted with the pipeline's KMS key."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.artifacts.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" && r.apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.pipeline.arn
    ])
    error_message = "The artifact bucket must default to SSE-KMS with the pipeline's key."
  }

  assert {
    condition     = aws_kms_key.pipeline.enable_key_rotation
    error_message = "The pipeline key must rotate."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.artifacts.block_public_acls,
      aws_s3_bucket_public_access_block.artifacts.block_public_policy,
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls,
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets,
    ])
    error_message = "The artifact bucket must block all public access."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.artifacts.rule[0].status == "Enabled" && aws_s3_bucket_lifecycle_configuration.artifacts.rule[0].expiration[0].days == 30 && aws_s3_bucket_lifecycle_configuration.artifacts.rule[0].noncurrent_version_expiration[0].noncurrent_days == 7
    error_message = "Artifacts must expire after 30 days and old versions after 7."
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement[0].Effect == "Deny" && jsondecode(aws_s3_bucket_policy.artifacts.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "The artifact bucket must refuse requests without TLS."
  }

  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.codebuild : g.kms_key_id == aws_kms_key.pipeline.arn])
    error_message = "CodeBuild logs must be encrypted with the pipeline's key."
  }

  assert {
    condition     = aws_codebuild_project.build.encryption_key == aws_kms_key.pipeline.arn && aws_codebuild_project.verify.encryption_key == aws_kms_key.pipeline.arn
    error_message = "CodeBuild must encrypt its artifacts with the pipeline's key."
  }
}

run "roles_name_every_action_and_scope_their_resources" {
  command = apply

  # No wildcard in any action of any role.
  assert {
    condition = alltrue([
      for p in [aws_iam_role_policy.pipeline.policy, aws_iam_role_policy.build.policy, aws_iam_role_policy.verify.policy] :
      alltrue([for a in flatten([for s in jsondecode(p).Statement : s.Action]) : !strcontains(a, "*")])
    ])
    error_message = "Every action must be named in full, with no wildcard."
  }

  # "*" as a resource only where the API takes no resource.
  assert {
    condition = alltrue([
      for p in [aws_iam_role_policy.pipeline.policy, aws_iam_role_policy.build.policy, aws_iam_role_policy.verify.policy] :
      alltrue([for s in jsondecode(p).Statement : contains(["EcrLogin", "EcsReadTaskDefinitions", "EcsListTasksInOneCluster"], s.Sid) if contains(flatten([s.Resource]), "*")])
    ])
    error_message = "Only ecr:GetAuthorizationToken, ecs:DescribeTaskDefinition and the cluster-bound ecs:ListTasks may use Resource \"*\"."
  }

  assert {
    condition = sort(distinct(flatten([for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement : s.Action]))) == tolist([
      "codebuild:BatchGetBuilds", "codebuild:StartBuild", "codeconnections:UseConnection",
      "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks",
      "ecs:RegisterTaskDefinition", "ecs:TagResource", "ecs:UpdateService", "iam:PassRole",
      "kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey",
      "s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject",
    ])
    error_message = "The pipeline role must have exactly the actions its stages need; it never pushes to ECR."
  }

  assert {
    condition     = length([for a in flatten([for s in jsondecode(aws_iam_role_policy.build.policy).Statement : s.Action]) : a if startswith(a, "ecs:") || startswith(a, "iam:")]) == 0
    error_message = "The build role must not reach ECS or IAM; only the pipeline deploys."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.build.policy).Statement : s.Resource if s.Sid == "EcrPushOneRepository"]) == var.ecr_repository_arn
    error_message = "The build role may push to one ECR repository only."
  }

  assert {
    condition = sort(distinct(flatten([for s in jsondecode(aws_iam_role_policy.verify.policy).Statement : s.Action]))) == tolist([
      "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks",
      "kms:Decrypt", "logs:CreateLogStream", "logs:PutLogEvents", "s3:GetObject", "s3:GetObjectVersion",
    ])
    error_message = "The verify role must only read the service and write its own logs."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement : s.Resource if s.Sid == "PassOnlyTheExecutionRoleToEcs"]) == var.execution_role_arn
    error_message = "iam:PassRole must be limited to the task execution role."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement : s.Resource if s.Sid == "EcsUpdateOneService"]) == var.ecs_service_arn
    error_message = "The pipeline may update one ECS service only."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement : s.Resource if s.Sid == "UseTheGitHubConnection"]) == aws_codeconnections_connection.github[0].arn
    error_message = "The pipeline may use its own connection only."
  }

  assert {
    condition     = jsondecode(aws_iam_role.pipeline.assume_role_policy).Statement[0].Principal.Service == "codepipeline.amazonaws.com" && jsondecode(aws_iam_role.pipeline.assume_role_policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == "arn:aws:codepipeline:us-east-1:111122223333:oidc-lab-pipeline"
    error_message = "The pipeline role must trust CodePipeline for this pipeline only."
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.build, aws_iam_role.verify] :
      jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "codebuild.amazonaws.com" && jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    ])
    error_message = "The CodeBuild roles must trust CodeBuild in this account only."
  }
}

run "s3_source_needs_no_connection" {
  command = apply

  variables {
    source_type       = "s3"
    github_repository = ""
  }

  assert {
    condition     = length(aws_codeconnections_connection.github) == 0
    error_message = "An S3 source must not create a connection."
  }

  assert {
    condition     = aws_codepipeline.this.stage[0].action[0].provider == "S3" && aws_codepipeline.this.stage[0].action[0].configuration.S3ObjectKey == "source/source.zip"
    error_message = "The S3 source must read source/source.zip from the artifact bucket."
  }

  assert {
    condition     = !contains(flatten([for s in jsondecode(aws_iam_role_policy.pipeline.policy).Statement : s.Action]), "codeconnections:UseConnection")
    error_message = "Without a connection, the pipeline role must not be able to use one."
  }
}

run "connection_source_needs_a_repository" {
  command = plan

  variables {
    github_repository = ""
  }

  expect_failures = [var.github_repository]
}

run "wildcard_branch_is_rejected" {
  command = plan

  variables {
    source_branch = "release-*"
  }

  expect_failures = [var.source_branch]
}
