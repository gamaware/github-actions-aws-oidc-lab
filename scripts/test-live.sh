#!/usr/bin/env bash
# Live test: create both stacks in a real AWS account, check the IAM policies
# as AWS evaluates them, then destroy everything. Manual only; CI never runs it.
#
#   make test-live                      # uses the AWS CLI profile "dev"
#   AWS_PROFILE_LIVE=sandbox make test-live
#   TEST_LIVE_CONFIRM=yes skips the confirmation prompt after the identity check.
#   TEST_LIVE_EXTRA_TAGS="Owner=you,Team=platform" adds tags that an SCP may
#   require on every create.
#
# What it does:
#   1. prints the caller identity so the operator can confirm the account;
#   2. copies both Terraform roots to a temporary directory (no state or plan
#      files land in the repository) and applies them with desired_count = 0
#      and the tag purpose = portfolio-test on every resource;
#   3. asks the IAM policy simulator whether each deploy role can do what the
#      pipeline needs, and cannot do anything next to it;
#   4. on exit, success or failure, destroys both stacks and checks that no
#      resource tagged purpose = portfolio-test remains.
#
# Needs: terraform, the AWS CLI, jq, a default VPC in the region (or set
# VPC_ID and SUBNET_ID), and IAM permissions to create roles and OIDC
# providers. The OIDC providers are created only if the account has none for
# the same URL, and are then destroyed with the stack.
# Never commit output from this script.

set -euo pipefail

PROFILE="${AWS_PROFILE_LIVE:-dev}"
REGION="${AWS_REGION_LIVE:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(openssl rand -hex 3)"
NAME="oidc-live-$RUN_ID"
WORK="$(mktemp -d)"
GITHUB_ROOT="$WORK/infra/terraform"
GITLAB_ROOT="$WORK/examples/gitlab-ci/terraform"
TAG_KEY="purpose"
TAG_VALUE="portfolio-test"
failures=0

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
tf() { terraform -chdir="$1" "${@:2}"; }

# Static keys in the environment would take precedence over the profile for
# Terraform and could point at another account.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

echo "Caller identity for profile $PROFILE:"
aws_ sts get-caller-identity --output table
if [[ "${TEST_LIVE_CONFIRM:-}" != "yes" ]]; then
  read -r -p "Create and destroy test resources in this account and $REGION? Type yes: " answer
  [[ "$answer" == "yes" ]] || { echo "Stopped."; exit 1; }
fi

# Fails the script if the call fails, instead of reading an error as "none".
list_providers() {
  aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text | tr '\t' '\n'
}
provider_exists() { grep -q "oidc-provider/$1\$" <<<"$2"; }

teardown() {
  local status=$?
  set +e
  local destroyed=true
  echo "--- Destroying the test stacks"
  if [[ -f "$GITLAB_ROOT/terraform.tfstate" ]]; then
    tf "$GITLAB_ROOT" destroy -auto-approve -input=false -no-color "${gitlab_vars[@]}" >/dev/null ||
      { echo "::error::terraform destroy failed for the GitLab stack; clean up $NAME-gitlab-deploy by hand."; destroyed=false; }
  fi
  if [[ -f "$GITHUB_ROOT/terraform.tfstate" ]]; then
    tf "$GITHUB_ROOT" destroy -auto-approve -input=false -no-color "${github_vars[@]}" >/dev/null ||
      { echo "::error::terraform destroy failed for the GitHub stack; clean up resources named $NAME by hand."; destroyed=false; }
  fi

  echo "--- Checking that nothing tagged $TAG_KEY=$TAG_VALUE remains"
  local leftovers="" tagged
  for _ in 1 2 3 4 5 6; do
    if ! tagged="$(aws_ resourcegroupstaggingapi get-resources \
      --tag-filters "Key=$TAG_KEY,Values=$TAG_VALUE" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text)"; then
      leftovers="(the tagging API call failed; check the account by hand)"
      break
    fi
    leftovers="$(tr '\t' '\n' <<<"$tagged" | grep "$NAME" |
      while read -r arn; do
        # A destroyed KMS key waits out its deletion window; ECS clusters and
        # task definitions stay visible as INACTIVE. None is a leftover.
        case "$arn" in
          *:kms:*)
            state="$(aws_ kms describe-key --key-id "$arn" --query KeyMetadata.KeyState --output text)"
            [[ "$state" == "PendingDeletion" ]] || echo "$arn"
            ;;
          *:ecs:*:cluster/*)
            state="$(aws_ ecs describe-clusters --clusters "$arn" --query 'clusters[0].status' --output text)"
            [[ "$state" == "INACTIVE" ]] || echo "$arn"
            ;;
          *:ecs:*:task-definition/*)
            state="$(aws_ ecs describe-task-definition --task-definition "$arn" \
              --query taskDefinition.status --output text)"
            [[ "$state" == "INACTIVE" || "$state" == "DELETE_IN_PROGRESS" ]] || echo "$arn"
            ;;
          *) echo "$arn" ;;
        esac
      done)"
    [[ -z "$leftovers" ]] && break
    sleep 10
  done
  for role in "$NAME-github-deploy" "$NAME-gitlab-deploy" "$NAME-task-execution"; do
    if aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
      leftovers+=$'\n'"role/$role"
    fi
  done
  local remaining
  if remaining="$(list_providers)"; then
    if [[ "$github_provider" == true ]] && provider_exists token.actions.githubusercontent.com "$remaining"; then
      leftovers+=$'\n'"GitHub OIDC provider created by this run"
    fi
    if [[ "$gitlab_provider" == true ]] && provider_exists gitlab.com "$remaining"; then
      leftovers+=$'\n'"GitLab OIDC provider created by this run"
    fi
  else
    leftovers+=$'\n'"(could not list OIDC providers; check them by hand)"
  fi
  if [[ "$destroyed" == true ]]; then
    rm -rf "$WORK"
  else
    echo "State kept in $WORK for a manual terraform destroy."
  fi

  if [[ -n "${leftovers//[$'\n ']/}" ]]; then
    echo "::error::Resources left behind:"
    echo "$leftovers"
    exit 1
  fi
  echo "Nothing tagged $TAG_KEY=$TAG_VALUE remains for $NAME."
  exit "$status"
}
github_vars=()
gitlab_vars=()
github_provider=false
gitlab_provider=false
trap teardown EXIT

vpc_id="${VPC_ID:-$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
[[ "$vpc_id" != "None" && -n "$vpc_id" ]] || { echo "::error::No default VPC in $REGION; set VPC_ID and SUBNET_ID."; exit 1; }
subnet_id="${SUBNET_ID:-$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" \
  --query 'Subnets[0].SubnetId' --output text)}"
[[ "$subnet_id" != "None" && -n "$subnet_id" ]] || { echo "::error::No subnet in $vpc_id; set SUBNET_ID."; exit 1; }

# Create a provider only when the account has none for that URL; an existing
# one is read through a data source and never destroyed.
providers="$(list_providers)"
github_provider=true
provider_exists token.actions.githubusercontent.com "$providers" && github_provider=false
gitlab_provider=true
provider_exists gitlab.com "$providers" && gitlab_provider=false

# Same relative layout as the repository: the GitLab root reads the deploy
# policy template from ../../../infra/terraform.
mkdir -p "$WORK/infra" "$WORK/examples/gitlab-ci"
cp -R "$REPO_ROOT/infra/terraform" "$WORK/infra/terraform"
cp -R "$REPO_ROOT/examples/gitlab-ci/terraform" "$WORK/examples/gitlab-ci/terraform"
# Only tracked configuration: no local state, variables or backend files.
for root in "$GITHUB_ROOT" "$GITLAB_ROOT"; do
  rm -rf "$root/.terraform" "$root"/*.tfstate* "$root"/*.tfvars "$root"/*.tfvars.json "$root/backend.tf"
done

export AWS_PROFILE="$PROFILE" AWS_REGION="$REGION"
tags="{\"$TAG_KEY\"=\"$TAG_VALUE\""
if [[ -n "${TEST_LIVE_EXTRA_TAGS:-}" ]]; then
  IFS=, read -r -a extra_tags <<<"$TEST_LIVE_EXTRA_TAGS"
  for pair in "${extra_tags[@]}"; do
    [[ "$pair" == ?*=* ]] || { echo "::error::TEST_LIVE_EXTRA_TAGS takes key=value pairs, got '$pair'."; exit 1; }
    tags+=",\"${pair%%=*}\"=\"${pair#*=}\""
  done
fi
tags+="}"

github_vars=(
  -var "name=$NAME" -var "aws_region=$REGION"
  -var "github_owner=example-owner" -var "github_repo=example-repo"
  -var "vpc_id=$vpc_id" -var "subnet_ids=[\"$subnet_id\"]"
  -var "create_oidc_provider=$github_provider" -var "desired_count=0" -var "tags=$tags"
)

echo "--- Applying the GitHub stack as $NAME"
tf "$GITHUB_ROOT" init -input=false -no-color >/dev/null
tf "$GITHUB_ROOT" apply -auto-approve -input=false -no-color "${github_vars[@]}" >/dev/null

out() { tf "$GITHUB_ROOT" output -raw "$1"; }
ecr_arn="$(out ecr_repository_arn)"
service_arn="$(out ecs_service_arn)"
execution_arn="$(out execution_role_arn)"
cluster_arn="$(out ecs_cluster_arn)"
github_role="$(out deploy_role_arn)"

gitlab_vars=(
  -var "name=$NAME" -var "aws_region=$REGION"
  -var "gitlab_project_path=harbor-goods/storefront"
  -var "ecr_repository_arn=$ecr_arn" -var "ecs_cluster_arn=$cluster_arn"
  -var "ecs_service_arn=$service_arn" -var "execution_role_arn=$execution_arn"
  -var "task_definition_family=$NAME"
  -var "create_oidc_provider=$gitlab_provider" -var "tags=$tags"
)

echo "--- Applying the GitLab stack"
tf "$GITLAB_ROOT" init -input=false -no-color >/dev/null
tf "$GITLAB_ROOT" apply -auto-approve -input=false -no-color "${gitlab_vars[@]}" >/dev/null
gitlab_role="$(tf "$GITLAB_ROOT" output -raw deploy_role_arn)"

other_repo="${ecr_arn%/*}/not-$NAME"
other_role="${execution_arn%/*}/$NAME-github-deploy"

# expect ROLE_ARN ACTION RESOURCE DECISION [CONTEXT_ENTRY]
expect() {
  local role="$1" action="$2" resource="$3" want="$4"
  local args=(--policy-source-arn "$role" --action-names "$action" --resource-arns "$resource")
  if [[ $# -ge 5 ]]; then
    args+=(--context-entries "$5")
  fi
  local got
  got="$(aws_ iam simulate-principal-policy "${args[@]}" \
    --query 'EvaluationResults[0].EvalDecision' --output text)"
  if [[ "$got" == "$want" ]]; then
    echo "ok    ${role##*/}  $action  ${resource##*:}  $got"
  else
    echo "FAIL  ${role##*/}  $action  ${resource##*:}  got $got, expected $want"
    failures=$((failures + 1))
  fi
}

passed_to_ecs="ContextKeyName=iam:PassedToService,ContextKeyValues=ecs-tasks.amazonaws.com,ContextKeyType=string"
passed_to_lambda="ContextKeyName=iam:PassedToService,ContextKeyValues=lambda.amazonaws.com,ContextKeyType=string"

echo "--- IAM policy simulator"
for role in "$github_role" "$gitlab_role"; do
  expect "$role" ecr:PutImage "$ecr_arn" allowed
  expect "$role" ecr:PutImage "$other_repo" implicitDeny
  expect "$role" ecs:UpdateService "$service_arn" allowed
  expect "$role" ecs:UpdateService "${service_arn%/*}/other-service" implicitDeny
  expect "$role" iam:PassRole "$execution_arn" allowed "$passed_to_ecs"
  expect "$role" iam:PassRole "$execution_arn" implicitDeny "$passed_to_lambda"
  expect "$role" iam:PassRole "$other_role" implicitDeny "$passed_to_ecs"
  expect "$role" iam:CreateRole "$other_role" implicitDeny
  expect "$role" s3:ListAllMyBuckets "*" implicitDeny
done

echo "--- Trust policies as stored by IAM"
github_sub="$(aws_ iam get-role --role-name "${github_role##*/}" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub"' \
  --output text)"
gitlab_sub="$(aws_ iam get-role --role-name "${gitlab_role##*/}" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."gitlab.com:sub"' --output text)"
for pair in "$github_sub|repo:example-owner/example-repo:environment:production" \
  "$gitlab_sub|project_path:harbor-goods/storefront:ref_type:branch:ref:main"; do
  if [[ "${pair%%|*}" == "${pair#*|}" ]]; then
    echo "ok    subject ${pair#*|}"
  else
    echo "FAIL  subject ${pair%%|*}, expected ${pair#*|}"
    failures=$((failures + 1))
  fi
done

if ((failures > 0)); then
  echo "::error::$failures live check(s) failed."
  exit 1
fi
echo "All live checks passed."
