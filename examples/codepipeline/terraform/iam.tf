# Three roles, one per principal: the pipeline, the build project and the
# verify project. Every action is named in full and every statement names the
# resources of this pipeline, except the few API calls that take no resource
# (tests/codepipeline.tftest.hcl asserts both).
#
# Policies are built with jsonencode rather than aws_iam_policy_document, so
# the mocked terraform test sees the real JSON.

locals {
  pipeline_arn       = "arn:${local.partition}:codepipeline:${var.aws_region}:${local.account_id}:${local.pipeline_name}"
  build_project_arn  = "arn:${local.partition}:codebuild:${var.aws_region}:${local.account_id}:project/${var.name}-build"
  verify_project_arn = "arn:${local.partition}:codebuild:${var.aws_region}:${local.account_id}:project/${var.name}-verify"

  artifact_statements = [
    {
      Sid      = "ArtifactBucket"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning"]
      Resource = local.artifact_arn
    },
    {
      Sid      = "ArtifactObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
      Resource = "${local.artifact_arn}/*"
    },
    {
      Sid      = "ArtifactKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey"]
      Resource = aws_kms_key.pipeline.arn
    },
  ]

  # The verify project only reads the source artifact.
  artifact_read_statements = [
    {
      Sid      = "ReadArtifactObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion"]
      Resource = "${local.artifact_arn}/*"
    },
    {
      Sid      = "DecryptArtifacts"
      Effect   = "Allow"
      Action   = "kms:Decrypt"
      Resource = aws_kms_key.pipeline.arn
    },
  ]

  # ECS reads that take no resource-level permission, or that the verify
  # script needs across the cluster, limited by condition where IAM allows it.
  ecs_read_statements = [
    {
      Sid      = "EcsReadTaskDefinitions"
      Effect   = "Allow"
      Action   = "ecs:DescribeTaskDefinition"
      Resource = "*"
    },
    {
      Sid       = "EcsListTasksInOneCluster"
      Effect    = "Allow"
      Action    = "ecs:ListTasks"
      Resource  = "*"
      Condition = { ArnEquals = { "ecs:cluster" = var.ecs_cluster_arn } }
    },
    {
      Sid      = "EcsDescribeTasksInOneCluster"
      Effect   = "Allow"
      Action   = "ecs:DescribeTasks"
      Resource = local.ecs_task_arn
    },
  ]

  pipeline_policy = {
    Version = "2012-10-17"
    Statement = concat(
      local.artifact_statements,
      local.source_is_s3 ? [] : [{
        Sid      = "UseTheGitHubConnection"
        Effect   = "Allow"
        Action   = "codeconnections:UseConnection"
        Resource = aws_codeconnections_connection.github[0].arn
      }],
      [
        {
          Sid      = "RunThePipelineProjects"
          Effect   = "Allow"
          Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
          Resource = [aws_codebuild_project.build.arn, aws_codebuild_project.verify.arn]
        },
        {
          Sid      = "EcsRegisterOneFamily"
          Effect   = "Allow"
          Action   = "ecs:RegisterTaskDefinition"
          Resource = local.task_definition_family_arn
          Condition = {
            "ForAllValues:StringEquals" = { "ecs:compute-compatibility" = ["FARGATE"] }
            StringEqualsIfExists        = { "ecs:privileged" = "false" }
          }
        },
        {
          Sid       = "EcsTagNewRevisions"
          Effect    = "Allow"
          Action    = "ecs:TagResource"
          Resource  = local.task_definition_family_arn
          Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } }
        },
        {
          Sid      = "EcsUpdateOneService"
          Effect   = "Allow"
          Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
          Resource = var.ecs_service_arn
          Condition = {
            ArnLikeIfExists      = { "ecs:task-definition" = local.task_definition_family_arn }
            StringEqualsIfExists = { "ecs:enable-execute-command" = "false" }
          }
        },
        {
          Sid       = "PassOnlyTheExecutionRoleToEcs"
          Effect    = "Allow"
          Action    = "iam:PassRole"
          Resource  = var.execution_role_arn
          Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
        },
      ],
      local.ecs_read_statements,
    )
  }

  build_policy = {
    Version = "2012-10-17"
    Statement = concat(local.artifact_statements, [
      {
        Sid      = "WriteBuildLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.codebuild["build"].arn}:*"
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushOneRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = var.ecr_repository_arn
      },
    ])
  }

  verify_policy = {
    Version = "2012-10-17"
    Statement = concat(local.artifact_read_statements, [
      {
        Sid      = "WriteVerifyLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.codebuild["verify"].arn}:*"
      },
      {
        Sid      = "EcsDescribeOneService"
        Effect   = "Allow"
        Action   = "ecs:DescribeServices"
        Resource = var.ecs_service_arn
      },
    ], local.ecs_read_statements)
  }
}

resource "aws_iam_role" "pipeline" {
  name        = "${var.name}-codepipeline"
  description = "Runs ${local.pipeline_name}: reads the source, starts its CodeBuild projects, deploys to ${local.service_name}."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.pipeline_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "run-one-pipeline"
  role   = aws_iam_role.pipeline.id
  policy = jsonencode(local.pipeline_policy)
}

resource "aws_iam_role" "build" {
  name        = "${var.name}-codebuild-build"
  description = "Used by the ${var.name}-build project to test, scan and push one ECR repository."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.build_project_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "build" {
  name   = "build-and-push-one-repository"
  role   = aws_iam_role.build.id
  policy = jsonencode(local.build_policy)
}

resource "aws_iam_role" "verify" {
  name        = "${var.name}-codebuild-verify"
  description = "Used by the ${var.name}-verify project to read the state of one ECS service."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.verify_project_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "verify" {
  name   = "read-one-service"
  role   = aws_iam_role.verify.id
  policy = jsonencode(local.verify_policy)
}
