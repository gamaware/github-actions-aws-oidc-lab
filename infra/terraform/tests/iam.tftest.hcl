# Offline tests for the IAM trust and permission policies. The AWS provider is
# mocked, so no credentials are needed and nothing is created. The policies are
# rendered from templates in Terraform itself, so their JSON is real even
# though every AWS resource is fake. Run with `terraform test` in infra/terraform/.

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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:111122223333:repository/oidc-lab"
      repository_url = "111122223333.dkr.ecr.us-east-1.amazonaws.com/oidc-lab"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:111122223333:cluster/oidc-lab"
    }
  }

  mock_resource "aws_ecs_service" {
    defaults = {
      id = "arn:aws:ecs:us-east-1:111122223333:service/oidc-lab/oidc-lab"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:/ecs/oidc-lab"
    }
  }
}

# Distinct ARNs for the two roles, so the PassRole test can tell them apart.
override_resource {
  target = aws_iam_role.execution
  values = {
    arn = "arn:aws:iam::111122223333:role/oidc-lab-task-execution"
  }
}

override_resource {
  target = aws_iam_role.deploy
  values = {
    arn = "arn:aws:iam::111122223333:role/oidc-lab-github-deploy"
  }
}

variables {
  github_owner = "example-owner"
  github_repo  = "example-repo"
  vpc_id       = "vpc-00000000000000000"
  subnet_ids   = ["subnet-00000000000000000"]
}

run "deploy_trust_accepts_exactly_the_production_environment" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement) == 1
    error_message = "The deploy trust policy must have exactly one statement."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The deploy role must be assumable only with a web identity token."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github[0].arn
    error_message = "The deploy role must trust only the GitHub OIDC provider."
  }

  # Only StringEquals: no StringLike, no ForAnyValue, no other operator.
  assert {
    condition     = keys(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    error_message = "The deploy trust policy must use StringEquals only."
  }

  assert {
    condition = keys(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals) == [
      "token.actions.githubusercontent.com:aud",
      "token.actions.githubusercontent.com:sub",
    ]
    error_message = "The deploy trust policy must check exactly aud and sub."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The audience must be sts.amazonaws.com."
  }

  assert {
    condition = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:example-owner/example-repo:environment:production",
    ]
    error_message = "The deploy role must accept exactly one subject: the production environment of this repository."
  }

  assert {
    condition     = !strcontains(aws_iam_role.deploy.assume_role_policy, "*") && !strcontains(aws_iam_role.deploy.assume_role_policy, "?")
    error_message = "The deploy trust policy must not contain wildcards."
  }
}

run "deploy_permissions_have_no_wildcard_actions_and_few_wildcard_resources" {
  command = apply

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : [
        for a in flatten([s.Action]) : !strcontains(a, "*")
      ]
    ]))
    error_message = "Every deploy action must be named in full, with no wildcards."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Effect == "Allow" && !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")])
    error_message = "The deploy policy must not use NotAction or NotResource."
  }

  # Resource "*" only where the action has no resource-level permissions,
  # and ListTasks is still pinned to one cluster by a condition.
  assert {
    condition = sort([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Sid if contains(flatten([s.Resource]), "*")
    ]) == tolist(["EcrLogin", "EcsListTasksInOneCluster", "EcsReadTaskDefinitions"])
    error_message = "Only EcrLogin, EcsReadTaskDefinitions and EcsListTasksInOneCluster may use Resource \"*\"."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Condition.ArnEquals["ecs:cluster"] if s.Sid == "EcsListTasksInOneCluster"
    ]) == aws_ecs_cluster.this.arn
    error_message = "ecs:ListTasks must be limited to the lab's cluster."
  }

  assert {
    condition = distinct(flatten([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : [
        for a in flatten([s.Action]) : a if startswith(a, "iam:")
      ]
    ])) == tolist(["iam:PassRole"])
    error_message = "The only IAM action the deploy role may have is iam:PassRole."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Action == "iam:PassRole"
    ]) == aws_iam_role.execution.arn
    error_message = "iam:PassRole must be limited to the task execution role."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Condition.StringEquals["iam:PassedToService"] if s.Action == "iam:PassRole"
    ]) == "ecs-tasks.amazonaws.com"
    error_message = "iam:PassRole must be limited to ecs-tasks.amazonaws.com."
  }

  # ForAllValues is true when the key is absent, so the Null condition makes
  # requiresCompatibilities mandatory for the Fargate-only restriction.
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Condition.Null["ecs:compute-compatibility"] if s.Sid == "EcsRegisterOneFamily"
    ]) == "false"
    error_message = "ecs:RegisterTaskDefinition must require the compute-compatibility key."
  }

  assert {
    condition     = length(aws_iam_role_policy.plan) == 0 && length(aws_iam_role.plan) == 0
    error_message = "The plan role must be off by default."
  }
}

run "plan_role_trusts_only_pull_requests_and_can_only_read" {
  command = apply

  variables {
    create_plan_role = true
    state_bucket     = "example-state-bucket"
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    error_message = "The plan trust policy must use StringEquals only."
  }

  assert {
    condition     = jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The plan role audience must be sts.amazonaws.com."
  }

  assert {
    condition = jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:example-owner/example-repo:pull_request",
    ]
    error_message = "The plan role must accept exactly the pull_request subject of this repository."
  }

  assert {
    condition     = !strcontains(aws_iam_role.plan[0].assume_role_policy, "*")
    error_message = "The plan trust policy must not contain wildcards."
  }

  # Read-only: every action is a Describe, Get or List call named in full.
  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.plan[0].policy).Statement : [
        for a in flatten([s.Action]) : can(regex("^[a-z0-9]+:(Describe|Get|List)[A-Za-z]+$", a))
      ]
    ]))
    error_message = "The plan role may only have Describe, Get and List actions, named in full."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.plan[0].policy).Statement : s.Resource if s.Sid == "ReadStateObject"
    ]) == "arn:aws:s3:::example-state-bucket/github-actions-aws-oidc-lab/terraform.tfstate"
    error_message = "The plan role may read only this stack's state object."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.plan[0].policy).Statement : s.Condition.StringEquals["s3:prefix"] if s.Sid == "ListStateBucket"
    ]) == ["env:/", "github-actions-aws-oidc-lab/terraform.tfstate"]
    error_message = "The plan role may list only the workspace prefix and this stack's state key."
  }
}

run "wildcard_owner_is_rejected" {
  command = plan

  variables {
    github_owner = "*"
  }

  expect_failures = [var.github_owner]
}

run "wildcard_repository_is_rejected" {
  command = plan

  variables {
    github_repo = "example-*"
  }

  expect_failures = [var.github_repo]
}

run "wildcard_environment_is_rejected" {
  command = plan

  variables {
    github_environment = "prod*"
  }

  expect_failures = [var.github_environment]
}

run "plan_role_without_state_bucket_is_rejected" {
  command = plan

  variables {
    create_plan_role = true
  }

  expect_failures = [var.state_bucket]
}
