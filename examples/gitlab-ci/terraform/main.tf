data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # Condition keys for an OIDC provider are prefixed with the issuer host.
  issuer_host = trimprefix(var.gitlab_url, "https://")

  # GitLab's default subject names the project, the ref type and the ref. It
  # carries no environment, so the protected branch is the boundary
  # (docs/adr/0009-gitlab-ci-example.md).
  trusted_subjects = [
    "project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.gitlab_branch}",
  ]

  cluster_name = element(split("/", var.ecs_cluster_arn), 1)
  arn_prefix   = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.gitlab[0].arn : data.aws_iam_openid_connect_provider.gitlab[0].arn
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count = var.create_oidc_provider ? 1 : 0

  url            = var.gitlab_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "gitlab" {
  count = var.create_oidc_provider ? 0 : 1

  url = var.gitlab_url
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-gitlab-deploy"
  description          = "Assumed by GitLab CI in ${var.gitlab_project_path} through OIDC to deploy ${var.name}."
  max_session_duration = 3600

  assume_role_policy = templatefile("${path.module}/policies/trust-policy.json.tftpl", {
    oidc_provider_arn = local.oidc_provider_arn
    issuer_host       = local.issuer_host
    subjects          = local.trusted_subjects
  })
}

# The same permission policy as the GitHub deploy role, from the same
# template: one repository, one service, one execution role to pass.
resource "aws_iam_role_policy" "deploy" {
  name = "deploy-one-service"
  role = aws_iam_role.deploy.id

  policy = templatefile("${path.module}/../../../infra/terraform/policies/deploy-policy.json.tftpl", {
    ecr_repository_arn = var.ecr_repository_arn
    ecs_service_arn    = var.ecs_service_arn
    execution_role_arn = var.execution_role_arn
    ecs_cluster_arn    = var.ecs_cluster_arn
    ecs_task_arn       = "${local.arn_prefix}:task/${local.cluster_name}/*"

    task_definition_family_arn = "${local.arn_prefix}:task-definition/${var.task_definition_family}:*"
  })
}
