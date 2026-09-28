# Every target except the test-live targets runs offline: no AWS account, no credentials.
# CI's verify job runs the same `make verify`; results match when local tool versions match the ones the README
# lists. The other CI jobs (docs lint, gitleaks, container build and scan, Trivy on the repository, and the
# Semgrep, Trivy image and Checkov SARIF gates in security.yml) are not part of it.

UVX       ?= uvx
TERRAFORM ?= terraform
TFLINT    ?= tflint
TF_ROOTS  := infra/terraform examples/gitlab-ci/terraform examples/codepipeline/terraform tests/live/terraform
SHELL_FILES := $(wildcard scripts/*.sh .claude/hooks/*.sh)

PYTEST    := $(UVX) --with-requirements app/requirements-dev.txt pytest
RUFF      := $(UVX) ruff@0.16.9
CHECKOV   := $(UVX) checkov==3.3.19
SEMGREP   := $(UVX) semgrep==1.178.0
ACTIONLINT := $(UVX) --from actionlint-py==1.7.12.25 actionlint
ZIZMOR    := $(UVX) zizmor==1.30.1

.PHONY: verify test python terraform checkov shell dockerfile workflows image semgrep test-live test-live-codepipeline clean

## verify: everything CI runs in the verify job, offline
verify: test python terraform checkov shell dockerfile workflows
	@echo "verify: all checks passed"

## test: app unit tests, workflow rules, GitLab pipeline properties
test:
	$(PYTEST) -q

python:
	$(RUFF) check .
	$(RUFF) format --check .

## terraform: fmt, validate, mocked terraform test and tflint on every root
terraform:
	$(TERRAFORM) fmt -check -recursive
	@for root in $(TF_ROOTS); do \
	  echo "--- $$root"; \
	  $(TERRAFORM) -chdir=$$root init -backend=false -input=false > /dev/null || exit 1; \
	  $(TERRAFORM) -chdir=$$root validate -no-color || exit 1; \
	  $(TERRAFORM) -chdir=$$root test -no-color || exit 1; \
	  (cd $$root && $(TFLINT) --init --config .tflint.hcl > /dev/null && \
	    $(TFLINT) --config .tflint.hcl --format compact) || exit 1; \
	done

checkov:
	@for root in $(TF_ROOTS); do \
	  $(CHECKOV) --directory $$root --framework terraform --quiet --compact || exit 1; \
	done

shell:
	shellcheck --severity=style $(SHELL_FILES)
	shellharden --check $(SHELL_FILES)

dockerfile:
	hadolint app/Dockerfile

workflows:
	$(ACTIONLINT)
	$(ZIZMOR) --offline .github/workflows

## image: build the image and gate it with Trivy (needs Docker and the Trivy DB)
image:
	docker build --tag oidc-lab:local app
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 oidc-lab:local

## semgrep: the rulesets the security gate uses (downloads rules from the registry)
semgrep:
	$(SEMGREP) scan --metrics=off --error \
	  --config p/python --config p/dockerfile --config p/github-actions \
	  --config p/terraform --config p/secrets

## test-live: apply to the dev account, check IAM with the policy simulator, destroy.
## Manual only. Needs the AWS CLI profile `dev` (override with AWS_PROFILE_LIVE).
test-live:
	./scripts/test-live.sh

## test-live-codepipeline: apply the deploy target and the CodePipeline stack to the dev account,
## run the pipeline end to end (build, approve, deploy, verify), check its roles, destroy.
## Manual only. Needs the AWS CLI profile `dev` (override with AWS_PROFILE_LIVE).
test-live-codepipeline:
	./scripts/test-live-codepipeline.sh

clean:
	rm -rf .pytest_cache .ruff_cache
	@for root in $(TF_ROOTS); do rm -rf $$root/.terraform; done
