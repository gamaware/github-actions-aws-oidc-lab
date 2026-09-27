# Optional read-only role for `terraform plan` on pull requests that change
# infra/. It trusts only the pull_request subject of this repository and can
# read this stack's resources and state object, nothing else (docs/adr/0007).
locals {
  plan_subjects = ["repo:${local.github_repository}:pull_request"]
}

resource "aws_iam_role" "plan" {
  count = var.create_plan_role ? 1 : 0

  name                 = "${var.name}-github-plan"
  description          = "Assumed by pull request workflows in ${local.github_repository} to run a read-only terraform plan."
  max_session_duration = 3600

  assume_role_policy = templatefile("${path.module}/policies/plan-trust-policy.json.tftpl", {
    oidc_provider_arn = local.oidc_provider_arn
    subjects          = local.plan_subjects
  })
}

resource "aws_iam_role_policy" "plan" {
  count = var.create_plan_role ? 1 : 0

  name = "read-this-stack"
  role = aws_iam_role.plan[0].id

  policy = templatefile("${path.module}/policies/plan-policy.json.tftpl", {
    state_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}"
    state_object_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}/${var.state_key}"

    # The backend lists only the workspace prefix and this stack's key, so the
    # role cannot list other stacks' state in a shared bucket.
    state_list_prefixes = ["env:/", var.state_key]

    oidc_provider_arn  = local.oidc_provider_arn
    ecr_repository_arn = aws_ecr_repository.app.arn
    ecs_cluster_arn    = aws_ecs_cluster.this.arn
    ecs_service_arn    = aws_ecs_service.app.id
    kms_key_arn        = aws_kms_key.logs.arn
    log_group_arn      = aws_cloudwatch_log_group.app.arn

    task_definition_family_arn = local.task_definition_family_arn

    # Built from names so the role can also read itself without a cycle.
    role_arns = [for role in ["github-deploy", "github-plan", "task-execution"] :
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-${role}"
    ]
  })
}
