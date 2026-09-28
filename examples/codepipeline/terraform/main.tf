data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Names and URLs derived from the ARNs that infra/terraform outputs.
  ecr_repository_name = element(split("/", var.ecr_repository_arn), 1)
  ecr_repository_url  = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.ecr_repository_name}"
  cluster_name        = element(split("/", var.ecs_cluster_arn), 1)
  service_name        = element(split("/", var.ecs_service_arn), 2)

  ecs_arn_prefix             = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}"
  task_definition_family_arn = "${local.ecs_arn_prefix}:task-definition/${var.task_definition_family}:*"
  ecs_task_arn               = "${local.ecs_arn_prefix}:task/${local.cluster_name}/*"

  pipeline_name = "${var.name}-pipeline"
  artifact_arn  = aws_s3_bucket.artifacts.arn
  source_is_s3  = var.source_type == "s3"
}

# ---------------------------------------------------------------------------
# Encryption key for pipeline artifacts and CodeBuild logs
# ---------------------------------------------------------------------------

# Key policy: the account administers the key through IAM, and CloudWatch Logs
# may use it only for this pipeline's CodeBuild log groups. The roles get key
# access through their own IAM policies (iam.tf). "*" as the resource in a key
# policy means "this key".
resource "aws_kms_key" "pipeline" {
  description             = "${local.pipeline_name} artifacts and build logs"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogsForThisPipeline"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncryptFrom", "kms:ReEncryptTo"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.name}-*"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "pipeline" {
  name          = "alias/${local.pipeline_name}"
  target_key_id = aws_kms_key.pipeline.key_id
}

# ---------------------------------------------------------------------------
# Artifact bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  #checkov:skip=CKV_AWS_144:Artifacts are rebuilt from source; cross-region replication adds cost without a recovery need.
  #checkov:skip=CKV_AWS_18:CloudTrail data events are the audit trail for a bucket only the pipeline roles can write.
  #checkov:skip=CKV2_AWS_62:Nothing consumes events from the artifact bucket; the pipeline tracks its own executions.
  bucket_prefix = "${var.name}-pipeline-"
  force_destroy = var.artifact_bucket_force_destroy
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is required for an S3 source action and keeps overwritten
# artifacts until the lifecycle rule removes them.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.pipeline.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-pipeline-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = var.artifact_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.artifact_arn, "${local.artifact_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# ---------------------------------------------------------------------------
# Source: GitHub through CodeConnections
# ---------------------------------------------------------------------------

# Created in PENDING state. An account administrator completes the GitHub
# handshake once in the console (Developer Tools > Settings > Connections).
resource "aws_codeconnections_connection" "github" {
  count = local.source_is_s3 ? 0 : 1

  name          = "${var.name}-github"
  provider_type = "GitHub"
}

# ---------------------------------------------------------------------------
# CodeBuild: build and verify
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = toset(["build", "verify"])

  name              = "/aws/codebuild/${var.name}-${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.pipeline.arn
}

resource "aws_codebuild_project" "build" {
  #checkov:skip=CKV_AWS_316:docker build needs privileged mode; the project runs only buildspec-build.yml from the pipeline source.
  name           = "${var.name}-build"
  description    = "Tests, builds, scans with Trivy and pushes ${local.ecr_repository_name} by digest."
  service_role   = aws_iam_role.build.arn
  encryption_key = aws_kms_key.pipeline.arn
  build_timeout  = 30
  queued_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "ECR_REPOSITORY_URL"
      value = local.ecr_repository_url
    }

    environment_variable {
      name  = "CONTAINER_NAME"
      value = "app"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "examples/codepipeline/buildspec-build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["build"].name
    }

    s3_logs {
      status = "DISABLED"
    }
  }
}

resource "aws_codebuild_project" "verify" {
  name           = "${var.name}-verify"
  description    = "Checks that ${local.service_name} runs the new revision and digest after the deploy."
  service_role   = aws_iam_role.verify.arn
  encryption_key = aws_kms_key.pipeline.arn
  build_timeout  = 20
  queued_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false

    environment_variable {
      name  = "ECS_CLUSTER"
      value = local.cluster_name
    }

    environment_variable {
      name  = "ECS_SERVICE"
      value = local.service_name
    }

    environment_variable {
      name  = "ECS_TASK_FAMILY"
      value = var.task_definition_family
    }

    environment_variable {
      name  = "CONTAINER_NAME"
      value = "app"
    }

    environment_variable {
      name  = "APP_URL"
      value = var.app_url
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "examples/codepipeline/buildspec-verify.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["verify"].name
    }

    s3_logs {
      status = "DISABLED"
    }
  }
}

# ---------------------------------------------------------------------------
# The pipeline: Source, Build, Approve, Deploy, Verify
# ---------------------------------------------------------------------------

resource "aws_codepipeline" "this" {
  name          = local.pipeline_name
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"
  # One deploy at a time; a newer commit waits instead of replacing a rollout.
  execution_mode = "QUEUED"
  # Also set on the resource, not only through default_tags, so CreatePipeline
  # carries them for tag-on-create policies.
  tags = var.tags

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.pipeline.arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    dynamic "action" {
      for_each = local.source_is_s3 ? [] : [1]

      content {
        name             = "GitHub"
        category         = "Source"
        owner            = "AWS"
        provider         = "CodeStarSourceConnection"
        version          = "1"
        output_artifacts = ["SourceOutput"]

        configuration = {
          ConnectionArn        = aws_codeconnections_connection.github[0].arn
          FullRepositoryId     = var.github_repository
          BranchName           = var.source_branch
          DetectChanges        = "true"
          OutputArtifactFormat = "CODE_ZIP"
        }
      }
    }

    dynamic "action" {
      for_each = local.source_is_s3 ? [1] : []

      content {
        name             = "S3"
        category         = "Source"
        owner            = "AWS"
        provider         = "S3"
        version          = "1"
        output_artifacts = ["SourceOutput"]

        configuration = {
          S3Bucket             = aws_s3_bucket.artifacts.bucket
          S3ObjectKey          = var.source_object_key
          PollForSourceChanges = "false"
        }
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "TestBuildScanPush"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      namespace        = "BuildVariables"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "ProductionApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Deploy #{BuildVariables.IMAGE_URI} to ${local.service_name}. Tests and the Trivy gate passed."
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "EcsDeploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["BuildOutput"]

      configuration = {
        ClusterName       = local.cluster_name
        ServiceName       = local.service_name
        FileName          = "imagedefinitions.json"
        DeploymentTimeout = "15"
      }
    }
  }

  stage {
    name = "Verify"

    action {
      name            = "VerifyRollout"
      category        = "Test"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]

      configuration = {
        ProjectName = aws_codebuild_project.verify.name
        EnvironmentVariables = jsonencode([{
          name  = "EXPECTED_IMAGE_URI"
          value = "#{BuildVariables.IMAGE_URI}"
          type  = "PLAINTEXT"
        }])
      }
    }
  }
}
