# Copilot code review instructions

When reviewing pull requests in this repository:

- Flag suppressed lint rules. Findings are fixed; a Checkov skip is allowed only inline, next to the resource, with
  its reason.
- The deploy role must trust exactly one OIDC subject with `StringEquals`. Flag any wildcard, `StringLike` or new
  subject that has no assertion in `infra/terraform/tests/iam.tftest.hcl`.
- Workflows start from `permissions: {}`, pin actions to full commit SHAs, never use `pull_request_target`, and
  never give pull request jobs `id-token: write`.
- The GitLab example in `examples/gitlab-ci/` must keep AWS keys out of CI variables and use an `id_tokens` token
  with the `sts.amazonaws.com` audience.
- The CodePipeline example in `examples/codepipeline/` keeps the manual approval before the ECS deploy, pushes only
  after the tests and the Trivy gate, deploys by digest, and names every IAM action in full with a matching
  assertion in `terraform/tests/codepipeline.tftest.hcl`.
- No real account IDs, ARNs, IPs, emails or client names. Use placeholders or AWS documentation example IDs.
- Conventional commit titles; documentation and `CHANGELOG.md` updated with behavior changes.
