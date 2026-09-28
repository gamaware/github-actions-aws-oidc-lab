# 0012. Live tests run private-only

## Status

Accepted

## Context

`make test-live` and `make test-live-codepipeline` apply the Terraform roots to a real sandbox account. Both used the
default VPC, whose subnets route to an internet gateway. The CodePipeline test also ran its ECS task with
`assign_public_ip = true` so the task could reach ECR and CloudWatch Logs. Nothing listened on the task's public
address, but a live test should not depend on that: a later change to the task, its security group or the
variables would make the service reachable from the internet during a run.

`infra/terraform` is the production example. It takes the VPC and subnets as inputs and keeps `assign_public_ip`
and `ingress_cidr_blocks` as variables, because a client's network decides them.

## Decision

- Live runs create their own network from `tests/live/terraform/`: a VPC with private subnets only, no internet or NAT
  gateway, a route table with no routes besides the local one, and VPC endpoints for ECR (`ecr.api`, `ecr.dkr`), S3
  (gateway) and CloudWatch Logs. The scripts no longer look up the default VPC or accept `VPC_ID` and `SUBNET_ID`.
- The private settings of the deploy target live in one tracked file, `tests/live/deploy-target.tfvars.json`
  (`assign_public_ip = false`, `ingress_cidr_blocks = []`). The scripts pass it with `-var-file` and never set
  those variables themselves. The production example keeps its variables unchanged.
- Before each apply, the scripts plan with the exact live variables, convert the plan with `terraform show -json`
  and run `scripts/check_private_plan.py` on it. A violation stops the run before that root is applied, and the
  apply uses the saved plan, so what was checked is what gets created. The checker also refuses any Route 53
  resource and public S3, ECR, EKS or API endpoints.
- Health is read through the ECS API (`scripts/verify-deployment.sh` with no `APP_URL`) and the container health
  check inside the task, never over the internet.

## Consequences

- A live run cannot create an internet-facing resource without failing an offline test first and the pre-flight
  second.
- `make test-live-codepipeline` adds three interface endpoints in two Availability Zones for the length of the run,
  a few cents per run. `make test-live` runs no task and creates only the free S3 gateway endpoint.
- The deploy target is planned after the network is applied, because it needs the VPC and subnet IDs. The network
  root is itself checked before it is applied, and a later refusal destroys it on exit.
- CodeBuild runs outside the VPC and still pulls the Docker Hub base image during the build. The running task needs
  nothing beyond the endpoints.

## Compliance

Automated, in `make verify`:

- `tests/test_check_private_plan.py` tests the checker against private and internet-facing plans.
- `tests/live/terraform/tests/private_only.tftest.hcl` plans the live network and the deploy target with the live
  settings file under a mocked provider, and fails if a subnet maps public IPs, a route is added, the default
  security group gets a rule, a task gets a public IP or the task security group gets an inbound rule.
- `tests/test_live_config.py` fails if the live network declares an internet gateway, NAT gateway, Elastic IP,
  route or load balancer, or if a live script looks up the default VPC, sets `assign_public_ip` or
  `ingress_cidr_blocks`, or applies anything but a plan the pre-flight checked.

At run time, the pre-flight in both scripts refuses any plan that `scripts/check_private_plan.py` rejects.

## Notes

- Rules, pre-flight and health checks: [docs/live-test.md](../live-test.md).
- `scripts/check_private_plan.py` is shared across the portfolio's repositories and is copied unchanged.
