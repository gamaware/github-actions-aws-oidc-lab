# Live tests

Two manual targets create real resources in a sandbox account, check them and destroy them. CI never runs them.

| Target | Script | What it applies | What it checks |
| --- | --- | --- | --- |
| `make test-live` | `scripts/test-live.sh` | Live network, `infra/terraform` (no task), `examples/gitlab-ci/terraform` | Both deploy roles with the IAM policy simulator, trust policy subjects as IAM stores them |
| `make test-live-codepipeline` | `scripts/test-live-codepipeline.sh` | Live network with VPC endpoints, `infra/terraform` (one task), `examples/codepipeline/terraform` | The pipeline end to end (build, approval, ECS deploy, verify), the three pipeline roles with the IAM policy simulator, the deployed image by digest |

Both use the AWS CLI profile `dev` (override with `AWS_PROFILE_LIVE`), print the caller identity and ask for
confirmation before creating anything, tag every resource `purpose=portfolio-test`, destroy everything on exit, and
fail if a tagged resource or the run's VPC remains. Their output is never committed.

## Private-only

A live run cannot create anything reachable from the internet
([ADR 0012](adr/0012-live-tests-run-private-only.md)).

### Rules

- The live network is a dedicated VPC from `tests/live/terraform/`, never the default VPC or a VPC passed in by the
  operator. Its subnets do not map public IP addresses, and its route table holds only the local route and the S3
  gateway endpoint's route. The VPC has no internet gateway, no NAT gateway, and no Elastic IP.
- ECS tasks run with `assign_public_ip = false`. `tests/live/deploy-target.tfvars.json` sets it together with
  `ingress_cidr_blocks = []`, and the scripts pass that file to `infra/terraform` instead of setting either variable
  themselves.
- No security group allows ingress from `0.0.0.0/0` or `::/0`. The task security group has no inbound rule; the
  endpoint security group accepts HTTPS from the VPC's CIDR block only.
- AWS APIs are reached through VPC endpoints: `ecr.api`, `ecr.dkr` and `logs` as interface endpoints with private
  DNS, and S3 as a gateway endpoint for image layers. `make test-live` runs no task, so it creates only the free S3
  gateway endpoint.
- Neither live path creates a load balancer. One added later must set `internal = true`.

### Pre-flight

Before each root is applied, the script:

1. runs `terraform plan -out` with exactly the variables the apply uses;
2. writes `terraform show -json` of that plan to the run's temporary directory;
3. runs `python3 scripts/check_private_plan.py` on it, which exits 1 and names every internet-facing resource:
   an internet gateway, a public NAT gateway, an Elastic IP, a load balancer without `internal = true`, a security
   group ingress from `0.0.0.0/0` or `::/0`, an ECS service with `assign_public_ip`, a subnet that maps public IP
   addresses, a default route to an internet or NAT gateway, and a few more. It also refuses any Route 53 resource,
   a public EKS API endpoint and public S3 or ECR access (an ECR Public repository, an S3 website endpoint, a public
   bucket ACL, a public access block with any setting off, or a bucket or repository policy that allows any
   principal unless a condition limits it to an account, organization, principal, source or VPC). A public IP
   setting or route that stays unknown until apply is refused as well;
4. applies that saved plan, and only that plan.

The roots are applied in order (network, deploy target, then the GitLab or pipeline root), because the deploy target
needs the network's VPC and subnet IDs. A refused plan stops the run before its root is applied; roots applied before
it were checked the same way and are destroyed on exit.

### Offline tests

`make verify` runs these with no AWS account:

- `tests/test_check_private_plan.py`: the checker accepts a private plan and refuses each kind of internet-facing
  resource, with exit codes 0, 1 and 2.
- `tests/live/terraform/tests/private_only.tftest.hcl`: a mocked-provider `terraform test` that plans the live
  network (no public IP mapping, no routes, a default security group with no rules, endpoints reachable only from
  the VPC) and plans `infra/terraform` with the values in `tests/live/deploy-target.tfvars.json` (no public IP, no
  inbound rule). Setting `assign_public_ip` to `true` in that file fails the `deploy_target` run.
- `tests/test_live_config.py`: the live network declares no internet gateway, NAT gateway, Elastic IP, route or load
  balancer; the scripts never look up the default VPC, never set `assign_public_ip` or `ingress_cidr_blocks`, and
  apply only plans that the pre-flight checked.

### Health checks

Nothing calls the service over the network. The task's container health check requests `/health` on `127.0.0.1`
inside the task. The CodePipeline Verify stage runs `scripts/verify-deployment.sh` with no `APP_URL`, so it reads
health through the ECS API: the PRIMARY deployment's task definition and rollout state, and the tasks' `RUNNING` and
`HEALTHY` status and image digest. The script then reads the deployed image through `ecs describe-services` and
`ecs describe-task-definition`.

## Accounts with tag-enforcement SCPs

Some accounts deny creates that lack required tags. Pass them at run time with `TEST_LIVE_EXTRA_TAGS`, a
comma-separated list of `key=value` pairs that both scripts add to every resource; never commit the values:

```bash
TEST_LIVE_EXTRA_TAGS="Owner=you@example.com,Team=platform" make test-live
```

The account's policy simulator results then include its SCPs, so an action the deploy roles must not perform can
come back as `explicitDeny` instead of `implicitDeny`. The scripts count both as denied.

### CodePipeline under a tag SCP

In the maintainer's sandbox, the tag-enforcement SCP denies `codepipeline:CreatePipeline` with an explicit deny
even when the request carries every required tag: a debug trace of the create showed `Team`, `Owner`, `purpose`,
`Project` and `ManagedBy` in the request body. `make test-live-codepipeline` therefore stops at the pipeline apply
there, after the network and deploy target were checked and applied, and tears everything down. It is not run in
that account.

The CodePipeline path is covered offline instead:

- `examples/codepipeline/terraform/tests/codepipeline.tftest.hcl`: stage order with the approval before deploy, the
  `aws/codebuild/standard:7.0` image, the ECS deploy action, encryption, and each role's actions and resources,
  including `codeconnections:UseConnection` on the connection only and `ecs:TagResource` only for new task
  definition revisions.
- `tests/test_codepipeline_example.py`: the buildspecs' properties, including `python: 3.13`.

`make test-live` does not create a pipeline and runs in that account.
