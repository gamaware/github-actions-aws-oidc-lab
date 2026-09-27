#!/usr/bin/env bash
# Live test of the CodePipeline path: create the deploy target and the
# pipeline in a real AWS account, run the pipeline end to end, check the roles
# with the IAM policy simulator, then destroy everything. Manual only; CI
# never runs it.
#
#   make test-live-codepipeline               # uses the AWS CLI profile "dev"
#   AWS_PROFILE_LIVE=sandbox make test-live-codepipeline
#   TEST_LIVE_CONFIRM=yes skips the confirmation prompt after the identity check.
#   TEST_LIVE_EXTRA_TAGS="Owner=you,Team=platform" adds tags that an SCP may
#   require on every create.
#
# What it does:
#   1. prints the caller identity so the operator can confirm the account;
#   2. copies infra/terraform and examples/codepipeline/terraform to a
#      temporary directory (no state lands in the repository) and applies both
#      with the tag purpose = portfolio-test on every resource. The pipeline
#      uses the S3 source, so no GitHub connection handshake is needed; the
#      ECS service runs one task with a public IP and no inbound rule;
#   3. uploads `git archive HEAD` as the source zip and starts the pipeline;
#   4. asks the IAM policy simulator what each pipeline role can and cannot do;
#   5. approves the Approve stage once the build has pushed the image, and
#      waits for Deploy and Verify to succeed;
#   6. on exit, success or failure, deregisters the task definition revisions
#      the pipeline registered, destroys both stacks and checks that no
#      resource tagged purpose = portfolio-test remains.
#
# Needs: terraform, the AWS CLI, git, a default VPC with a public subnet in
# the region (or set VPC_ID and SUBNET_ID), and permissions to create IAM
# roles, KMS keys, S3 buckets, CodeBuild projects and pipelines. Takes about
# 15 minutes. Only committed files are built: commit before running it.
# Never commit output from this script.

set -euo pipefail

PROFILE="${AWS_PROFILE_LIVE:-dev}"
REGION="${AWS_REGION_LIVE:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(openssl rand -hex 3)"
NAME="cp-live-$RUN_ID"
WORK="$(mktemp -d)"
TARGET_ROOT="$WORK/infra/terraform"
PIPELINE_ROOT="$WORK/examples/codepipeline/terraform"
TAG_KEY="purpose"
TAG_VALUE="portfolio-test"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"
failures=0

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
tf() { terraform -chdir="$1" "${@:2}"; }

# Static keys in the environment would take precedence over the profile for
# Terraform and could point at another account.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

echo "Caller identity for profile $PROFILE:"
aws_ sts get-caller-identity --output table
if [[ "${TEST_LIVE_CONFIRM:-}" != "yes" ]]; then
  read -r -p "Create, run and destroy a test pipeline in this account and $REGION? Type yes: " answer
  [[ "$answer" == "yes" ]] || { echo "Stopped."; exit 1; }
fi

teardown() {
  local status=$?
  # Also +u: bash 3.2 (macOS) treats an empty array expansion as unbound.
  set +eu
  local destroyed=true
  # Stop running executions first, so the ECS deploy action cannot register a
  # revision after the ones below are deregistered.
  [[ -n "${pipeline:-}" ]] && stop_executions
  echo "--- Deregistering task definition revisions of $NAME"
  local revisions=()
  read -r -a revisions <<<"$(aws_ ecs list-task-definitions --family-prefix "$NAME" --status ACTIVE \
    --query 'taskDefinitionArns[]' --output text)"
  for arn in "${revisions[@]}"; do
    [[ "$arn" == "None" ]] || aws_ ecs deregister-task-definition --task-definition "$arn" >/dev/null
  done

  echo "--- Destroying the test stacks"
  if [[ -f "$PIPELINE_ROOT/terraform.tfstate" ]]; then
    tf "$PIPELINE_ROOT" destroy -auto-approve -input=false -no-color "${pipeline_vars[@]}" >/dev/null ||
      { echo "::error::terraform destroy failed for the pipeline stack; clean up resources named $NAME by hand."; destroyed=false; }
  fi
  if [[ -f "$TARGET_ROOT/terraform.tfstate" ]]; then
    tf "$TARGET_ROOT" destroy -auto-approve -input=false -no-color "${target_vars[@]}" >/dev/null ||
      { echo "::error::terraform destroy failed for the deploy target; clean up resources named $NAME by hand."; destroyed=false; }
  fi

  echo "--- Checking that nothing tagged $TAG_KEY=$TAG_VALUE remains"
  local leftovers="" tagged
  for _ in 1 2 3 4 5 6; do
    # Both roots tag every resource with Project = the run's name; KMS key
    # ARNs do not contain the name, so filter on the tag, not on the ARN.
    if ! tagged="$(aws_ resourcegroupstaggingapi get-resources \
      --tag-filters "Key=$TAG_KEY,Values=$TAG_VALUE" "Key=Project,Values=$NAME" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text)"; then
      leftovers="(the tagging API call failed; check the account by hand)"
      break
    fi
    leftovers="$(tr '\t' '\n' <<<"$tagged" | grep -v '^None$' |
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
  for role in "$NAME-codepipeline" "$NAME-codebuild-build" "$NAME-codebuild-verify" \
    "$NAME-github-deploy" "$NAME-task-execution"; do
    if aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
      leftovers+=$'\n'"role/$role"
    fi
  done
  if aws_ codepipeline get-pipeline --name "$NAME-pipeline" >/dev/null 2>&1; then
    leftovers+=$'\n'"pipeline/$NAME-pipeline"
  fi
  if [[ "$github_provider" == true ]] &&
    aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text |
    tr '\t' '\n' | grep -q 'oidc-provider/token.actions.githubusercontent.com$'; then
    leftovers+=$'\n'"GitHub OIDC provider created by this run"
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
# Abandons every in-progress execution of the pipeline, then waits briefly.
stop_executions() {
  local ids=()
  read -r -a ids <<<"$(aws_ codepipeline list-pipeline-executions --pipeline-name "$pipeline" \
    --query "pipelineExecutionSummaries[?status=='InProgress'].pipelineExecutionId" --output text)"
  for id in "${ids[@]}"; do
    [[ "$id" == "None" ]] || aws_ codepipeline stop-pipeline-execution --pipeline-name "$pipeline" \
      --pipeline-execution-id "$id" --abandon --reason "make test-live-codepipeline" >/dev/null
  done
  sleep 10
}
target_vars=()
pipeline_vars=()
github_provider=false
trap teardown EXIT

vpc_id="${VPC_ID:-$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
[[ "$vpc_id" != "None" && -n "$vpc_id" ]] || { echo "::error::No default VPC in $REGION; set VPC_ID and SUBNET_ID."; exit 1; }
subnet_id="${SUBNET_ID:-$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" \
  "Name=map-public-ip-on-launch,Values=true" --query 'Subnets[0].SubnetId' --output text)}"
[[ "$subnet_id" != "None" && -n "$subnet_id" ]] || { echo "::error::No public subnet in $vpc_id; set SUBNET_ID."; exit 1; }

# The deploy target root also defines the GitHub OIDC provider. Create it only
# when the account has none; an existing one is read and never destroyed.
providers="$(aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text)"
github_provider=true
tr '\t' '\n' <<<"$providers" | grep -q 'oidc-provider/token.actions.githubusercontent.com$' && github_provider=false

# Same relative layout as the repository.
mkdir -p "$WORK/infra" "$WORK/examples/codepipeline"
cp -R "$REPO_ROOT/infra/terraform" "$TARGET_ROOT"
cp -R "$REPO_ROOT/examples/codepipeline/terraform" "$PIPELINE_ROOT"
# Only tracked configuration: no local state, variables or backend files.
for root in "$TARGET_ROOT" "$PIPELINE_ROOT"; do
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

target_vars=(
  -var "name=$NAME" -var "aws_region=$REGION"
  -var "github_owner=example-owner" -var "github_repo=example-repo"
  -var "vpc_id=$vpc_id" -var "subnet_ids=[\"$subnet_id\"]" -var "assign_public_ip=true"
  -var "create_oidc_provider=$github_provider" -var "desired_count=1" -var "tags=$tags"
)

echo "--- Applying the deploy target as $NAME"
tf "$TARGET_ROOT" init -input=false -no-color >/dev/null
tf "$TARGET_ROOT" apply -auto-approve -input=false -no-color "${target_vars[@]}" >/dev/null

out() { tf "$TARGET_ROOT" output -raw "$1"; }
ecr_arn="$(out ecr_repository_arn)"
service_arn="$(out ecs_service_arn)"
execution_arn="$(out execution_role_arn)"
cluster_arn="$(out ecs_cluster_arn)"

pipeline_vars=(
  -var "name=$NAME" -var "aws_region=$REGION" -var "source_type=s3"
  -var "ecr_repository_arn=$ecr_arn" -var "ecs_cluster_arn=$cluster_arn"
  -var "ecs_service_arn=$service_arn" -var "execution_role_arn=$execution_arn"
  -var "task_definition_family=$NAME" -var "artifact_bucket_force_destroy=true" -var "tags=$tags"
)

echo "--- Applying the pipeline stack"
tf "$PIPELINE_ROOT" init -input=false -no-color >/dev/null
tf "$PIPELINE_ROOT" apply -auto-approve -input=false -no-color "${pipeline_vars[@]}" >/dev/null
pout() { tf "$PIPELINE_ROOT" output -raw "$1"; }
pipeline="$(pout pipeline_name)"
bucket="$(pout artifact_bucket)"
pipeline_role="$(pout pipeline_role_arn)"
build_role="$(pout build_role_arn)"
verify_role="$(pout verify_role_arn)"

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
other_repo="${ecr_arn%/*}/not-$NAME"
other_service="${service_arn%/*}/other-service"

echo "--- IAM policy simulator"
expect "$build_role" ecr:PutImage "$ecr_arn" allowed
expect "$build_role" ecr:PutImage "$other_repo" implicitDeny
expect "$build_role" ecs:UpdateService "$service_arn" implicitDeny
expect "$build_role" iam:PassRole "$execution_arn" implicitDeny "$passed_to_ecs"
expect "$pipeline_role" ecs:UpdateService "$service_arn" allowed
expect "$pipeline_role" ecs:UpdateService "$other_service" implicitDeny
expect "$pipeline_role" ecr:PutImage "$ecr_arn" implicitDeny
expect "$pipeline_role" iam:PassRole "$execution_arn" allowed "$passed_to_ecs"
expect "$pipeline_role" iam:PassRole "$execution_arn" implicitDeny "$passed_to_lambda"
expect "$verify_role" ecs:DescribeServices "$service_arn" allowed
expect "$verify_role" ecs:UpdateService "$service_arn" implicitDeny
for role in "$pipeline_role" "$build_role" "$verify_role"; do
  expect "$role" iam:CreateRole "$execution_arn" implicitDeny
  expect "$role" s3:ListAllMyBuckets "*" implicitDeny
done

echo "--- Uploading the committed source and starting $pipeline"
# A new pipeline starts once on its own, before the source zip exists. Stop
# it, so it cannot pick up the zip and hold the Approve stage.
stop_executions
git -C "$REPO_ROOT" archive --format=zip --output "$WORK/source.zip" HEAD
aws_ s3 cp "$WORK/source.zip" "s3://$bucket/source/source.zip" --only-show-errors
execution_id="$(aws_ codepipeline start-pipeline-execution --name "$pipeline" \
  --query pipelineExecutionId --output text)"

execution_status() {
  aws_ codepipeline get-pipeline-execution --pipeline-name "$pipeline" \
    --pipeline-execution-id "$execution_id" --query pipelineExecution.status --output text
}

# approval_state prints "<execution id> <status> <token>" for the Approve action.
approval_state() {
  aws_ codepipeline get-pipeline-state --name "$pipeline" \
    --query "stageStates[?stageName=='Approve'] | [0].[latestExecution.pipelineExecutionId, actionStates[0].latestExecution.status, actionStates[0].latestExecution.token]" \
    --output text
}

echo "--- Waiting for Build to finish and Approve to open"
deadline=$((SECONDS + WAIT_SECONDS))
token=""
while ((SECONDS < deadline)); do
  status="$(execution_status)"
  [[ "$status" == "InProgress" ]] || { echo "::error::Execution $execution_id ended as $status before the approval."; exit 1; }
  read -r approve_execution approve_status approve_token <<<"$(approval_state)"
  if [[ "$approve_execution" == "$execution_id" && "$approve_status" == "InProgress" ]]; then
    token="$approve_token"
    break
  fi
  sleep 20
done
[[ -n "$token" && "$token" != "None" ]] || { echo "::error::Approve did not open within $WAIT_SECONDS seconds."; exit 1; }

echo "--- Approving the deploy"
aws_ codepipeline put-approval-result --pipeline-name "$pipeline" --stage-name Approve \
  --action-name ProductionApproval --token "$token" \
  --result "summary=Approved by make test-live-codepipeline,status=Approved" >/dev/null

echo "--- Waiting for Deploy and Verify"
status="InProgress"
while ((SECONDS < deadline)) && [[ "$status" == "InProgress" ]]; do
  sleep 20
  status="$(execution_status)"
done
if [[ "$status" == "Succeeded" ]]; then
  echo "ok    pipeline execution $execution_id Succeeded"
else
  echo "FAIL  pipeline execution $execution_id ended as $status"
  failures=$((failures + 1))
fi

echo "--- Deployed image"
deployed_task_definition="$(aws_ ecs describe-services --cluster "${cluster_arn##*/}" --services "${service_arn##*/}" \
  --query "services[0].deployments[?status=='PRIMARY'] | [0].taskDefinition" --output text)"
deployed_image="$(aws_ ecs describe-task-definition --task-definition "$deployed_task_definition" \
  --query 'taskDefinition.containerDefinitions[0].image' --output text)"
if [[ "$deployed_image" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "ok    service runs ${deployed_image##*/}"
else
  echo "FAIL  service runs $deployed_image, not an image by digest"
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "::error::$failures live check(s) failed."
  exit 1
fi
echo "All live checks passed."
