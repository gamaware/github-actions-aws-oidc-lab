data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  github_repository = "${var.github_owner}/${var.github_repo}"

  # The only OIDC subject the deploy role accepts. GitHub issues it only to a
  # job that declares `environment: production`, after the environment's
  # branch policy and required reviewer pass. Jobs on `main` without the
  # environment get a ref subject and are refused (docs/adr/0002).
  trusted_subjects = [
    "repo:${local.github_repository}:environment:${var.github_environment}",
  ]

  # Every revision of the lab's task definition family.
  task_definition_family_arn = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.app.family}:*"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-github-deploy"
  description          = "Assumed by GitHub Actions in ${local.github_repository} through OIDC to deploy ${var.name}."
  max_session_duration = 3600

  assume_role_policy = templatefile("${path.module}/policies/trust-policy.json.tftpl", {
    oidc_provider_arn = local.oidc_provider_arn
    subjects          = local.trusted_subjects
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-one-service"
  role = aws_iam_role.deploy.id

  policy = templatefile("${path.module}/policies/deploy-policy.json.tftpl", {
    ecr_repository_arn = aws_ecr_repository.app.arn
    ecs_service_arn    = aws_ecs_service.app.id
    execution_role_arn = aws_iam_role.execution.arn
    ecs_cluster_arn    = aws_ecs_cluster.this.arn
    ecs_task_arn       = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.this.name}/*"

    task_definition_family_arn = local.task_definition_family_arn
  })
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Used by the ECS agent to pull the image and write logs. The app itself
# needs no AWS access, so there is no task role.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-image-write-logs"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}
