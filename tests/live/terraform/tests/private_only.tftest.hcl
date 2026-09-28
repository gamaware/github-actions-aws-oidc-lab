# Offline proof that the live tests run private-only. The AWS provider is
# mocked, so nothing is created and no credentials are needed.
#
# - run "network" plans this root, the network every live run uses;
# - run "deploy_target" plans infra/terraform with the settings the live
#   scripts pass through ../deploy-target.tfvars.json.
#
# Setting assign_public_ip to true or adding ingress_cidr_blocks in that file,
# or adding a route, a public subnet or an internet gateway here, fails a run.
# scripts/check_private_plan.py checks the real plan again before each apply.

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

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:111122223333:repository/live-test"
      repository_url = "111122223333.dkr.ecr.us-east-1.amazonaws.com/live-test"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:111122223333:cluster/live-test"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:/ecs/live-test"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/live-test"
    }
  }
}

variables {
  name = "live-test"
  tags = { purpose = "portfolio-test" }
}

run "network" {
  command = plan

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false])
    error_message = "Live-test subnets must not map public IP addresses on launch."
  }

  assert {
    condition     = length(aws_route_table.private.route) == 0
    error_message = "The live-test route table may hold no routes besides the local one: no internet or NAT gateway."
  }

  assert {
    condition     = length(aws_default_security_group.live.ingress) == 0 && length(aws_default_security_group.live.egress) == 0
    error_message = "The default security group of the live-test VPC must have no rules."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.endpoints_https.cidr_ipv4 == var.cidr_block
    error_message = "The endpoints accept HTTPS only from inside the VPC."
  }

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr", "logs"])
    error_message = "Running tasks need the ecr.api, ecr.dkr and logs interface endpoints."
  }

  assert {
    condition     = alltrue([for endpoint in aws_vpc_endpoint.interface : endpoint.private_dns_enabled])
    error_message = "Interface endpoints need private DNS, so ECS resolves the regional service names to them."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "Image layers come from S3 through a gateway endpoint."
  }
}

run "network_without_tasks" {
  command = plan

  variables {
    interface_endpoints = false
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "make test-live runs no task and needs no interface endpoints."
  }
}

run "deploy_target" {
  command = plan

  module {
    source = "../../../infra/terraform"
  }

  variables {
    github_owner        = "example-owner"
    github_repo         = "example-repo"
    vpc_id              = "vpc-0123456789abcdef0"
    subnet_ids          = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    desired_count       = 1
    assign_public_ip    = jsondecode(file("../deploy-target.tfvars.json")).assign_public_ip
    ingress_cidr_blocks = jsondecode(file("../deploy-target.tfvars.json")).ingress_cidr_blocks
  }

  assert {
    condition     = alltrue([for net in aws_ecs_service.app.network_configuration : net.assign_public_ip == false])
    error_message = "Live-test ECS tasks must run with assign_public_ip = false."
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.app :
      !contains(["0.0.0.0/0", "::/0"], coalesce(rule.cidr_ipv4, rule.cidr_ipv6, "none"))
    ])
    error_message = "No live-test security group may allow ingress from 0.0.0.0/0 or ::/0."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.app) == 0
    error_message = "Live-test tasks accept no inbound traffic; health comes from the ECS and container health checks."
  }
}
