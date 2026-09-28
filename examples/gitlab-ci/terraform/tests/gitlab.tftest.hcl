# Offline tests for the GitLab deploy role. The AWS provider is mocked, so no
# credentials are needed and nothing is created. Run with `terraform test`.

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

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111122223333:oidc-provider/gitlab.com"
    }
  }
}

variables {
  gitlab_project_path    = "harbor-goods/storefront"
  ecr_repository_arn     = "arn:aws:ecr:us-east-1:111122223333:repository/oidc-lab"
  ecs_cluster_arn        = "arn:aws:ecs:us-east-1:111122223333:cluster/oidc-lab"
  ecs_service_arn        = "arn:aws:ecs:us-east-1:111122223333:service/oidc-lab/oidc-lab"
  execution_role_arn     = "arn:aws:iam::111122223333:role/oidc-lab-task-execution"
  task_definition_family = "oidc-lab"
}

run "trust_accepts_exactly_the_protected_main_branch" {
  command = apply

  assert {
    condition     = aws_iam_openid_connect_provider.gitlab[0].url == "https://gitlab.com" && aws_iam_openid_connect_provider.gitlab[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The provider must be gitlab.com with the sts.amazonaws.com audience."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement) == 1
    error_message = "The trust policy must have exactly one statement."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.gitlab[0].arn
    error_message = "The role must trust only the GitLab OIDC provider."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    error_message = "The trust policy must use StringEquals only."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals) == ["gitlab.com:aud", "gitlab.com:sub"]
    error_message = "The trust policy must check exactly aud and sub of the gitlab.com issuer."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["gitlab.com:aud"] == "sts.amazonaws.com"
    error_message = "The audience must be sts.amazonaws.com."
  }

  assert {
    condition = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["gitlab.com:sub"] == [
      "project_path:harbor-goods/storefront:ref_type:branch:ref:main",
    ]
    error_message = "The role must accept exactly one subject: the main branch of this project."
  }

  assert {
    condition     = !strcontains(aws_iam_role.deploy.assume_role_policy, "*") && !strcontains(aws_iam_role.deploy.assume_role_policy, "?")
    error_message = "The trust policy must not contain wildcards."
  }
}

run "permissions_match_the_github_deploy_role" {
  command = apply

  # Same Sids, same actions, from the shared template in infra/terraform.
  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Sid] == [
      "EcrLogin", "EcrPushOneRepository", "EcsReadTaskDefinitions", "EcsRegisterOneFamily",
      "EcsUpdateOneService", "EcsListTasksInOneCluster", "EcsDescribeTasksInOneCluster", "PassOnlyTheExecutionRoleToEcs",
    ]
    error_message = "The GitLab role must use the same deploy policy as the GitHub role."
  }

  assert {
    condition = sort(distinct(flatten([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action]))) == tolist([
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks",
      "ecs:RegisterTaskDefinition", "ecs:UpdateService", "iam:PassRole",
    ])
    error_message = "The GitLab role must have exactly the deploy actions, no more."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "EcsDescribeTasksInOneCluster"
    ]) == "arn:aws:ecs:us-east-1:111122223333:task/oidc-lab/*"
    error_message = "DescribeTasks must be limited to tasks in the lab's cluster."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "EcsRegisterOneFamily"
    ]) == "arn:aws:ecs:us-east-1:111122223333:task-definition/oidc-lab:*"
    error_message = "RegisterTaskDefinition must be limited to the lab's family."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "PassOnlyTheExecutionRoleToEcs"
    ]) == var.execution_role_arn
    error_message = "iam:PassRole must be limited to the task execution role."
  }
}

run "self_managed_instance_uses_its_host_in_condition_keys" {
  command = apply

  variables {
    gitlab_url = "https://gitlab.example.com"
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals) == ["gitlab.example.com:aud", "gitlab.example.com:sub"]
    error_message = "Condition keys must use the self-managed issuer host."
  }
}

run "wildcard_project_path_is_rejected" {
  command = plan

  variables {
    gitlab_project_path = "harbor-goods/*"
  }

  expect_failures = [var.gitlab_project_path]
}

run "project_path_without_group_is_rejected" {
  command = plan

  variables {
    gitlab_project_path = "storefront"
  }

  expect_failures = [var.gitlab_project_path]
}

run "wildcard_branch_is_rejected" {
  command = plan

  variables {
    gitlab_branch = "release-*"
  }

  expect_failures = [var.gitlab_branch]
}

run "issuer_with_path_is_rejected" {
  command = plan

  variables {
    gitlab_url = "https://gitlab.com/"
  }

  expect_failures = [var.gitlab_url]
}

run "wildcard_execution_role_is_rejected" {
  command = plan

  variables {
    execution_role_arn = "*"
  }

  expect_failures = [var.execution_role_arn]
}

run "wildcard_task_definition_family_is_rejected" {
  command = plan

  variables {
    task_definition_family = "*"
  }

  expect_failures = [var.task_definition_family]
}

run "wildcard_repository_arn_is_rejected" {
  command = plan

  variables {
    ecr_repository_arn = "arn:aws:ecr:us-east-1:111122223333:repository/*"
  }

  expect_failures = [var.ecr_repository_arn]
}
