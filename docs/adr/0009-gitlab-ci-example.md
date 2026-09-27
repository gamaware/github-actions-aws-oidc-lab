# 0009. Show the GitLab CI equivalent as a tested example, bound to the protected branch

## Status

Accepted

## Context

Clients deploy from GitHub Actions, GitLab CI or Jenkins. The lab proves the pattern on GitHub Actions end to end.
A GitLab team asks the same questions: can the pipeline reach AWS without stored keys, and which jobs can do it?

GitLab CI issues OIDC ID tokens to jobs that declare `id_tokens`, with an audience the job chooses. Its default
`sub` claim is `project_path:GROUP/PROJECT:ref_type:branch:ref:BRANCH`. Unlike GitHub, the subject carries the ref
but not the environment, so the environment-only trust of [ADR 0002](0002-environment-subject-only.md) cannot be
copied as is.

Three options were considered:

1. A second, full pipeline that runs in GitLab against a real project. It would need a GitLab project and runner
   the portfolio does not maintain.
2. Prose only, a paragraph in the README. Nothing would check it.
3. A pipeline file and a Terraform root in `examples/gitlab-ci/`, with offline tests on both.

## Decision

Option 3. `examples/gitlab-ci/` holds:

- `.gitlab-ci.yml`: the same stages as `deploy.yml` (test, build once as an OCI archive, Trivy gate, manual deploy
  by digest, `scripts/verify-deployment.sh`).
- `terraform/`: the GitLab OIDC provider and a deploy role whose trust policy accepts exactly
  `project_path:<project>:ref_type:branch:ref:main` with audience `sts.amazonaws.com`, using `StringEquals` only.
  Its permission policy is rendered from the same template as the GitHub role, so both roles reach one ECR
  repository, one ECS service and one execution role to pass.

Because the subject does not name the environment, the boundary is the protected `main` branch plus one rule in
the pipeline: only the deploy job declares `id_tokens`. A job without `id_tokens` receives no token, so it cannot
call STS even when it runs on `main`.

## Consequences

- The multi-tool claim of the CI/CD offer rests on code and tests, not on a sentence.
- Any job added to `main` with `id_tokens` and the `sts.amazonaws.com` audience could assume the role. The pipeline
  test fails if a second job declares `id_tokens`, and GitLab's protected branches limit who can change the file.
- The subject matches the branch by name. A fork merge request whose source branch is also named `main`, run in
  the parent project by a maintainer, would carry the trusted subject and could run its own `id_tokens` job. The
  example's README tells maintainers not to run fork pipelines in the parent project; this was not tested against
  GitLab.
- Protected environments with required approvals exist on paid GitLab tiers. On the free tier, the manual `when`
  rule is a click, not an approval gate. The README states this limit.
- The example is not run in GitLab by this repository's CI. The tests prove what the files say, not how GitLab
  and STS behave together.
- Jenkins has no built-in OIDC issuer, so it stays a documented pattern: [docs/jenkins-pattern.md](../jenkins-pattern.md).

## Compliance

Automated, in `make verify`:

- `examples/gitlab-ci/terraform/tests/gitlab.tftest.hcl` asserts the provider URL and audience, `StringEquals` as
  the only operator, exactly the `aud` and `sub` keys of the issuer host, the single `main` subject, no wildcards,
  the same statement IDs as the GitHub deploy policy, and that wildcard project paths, branches and issuer URLs
  with a path are refused.
- `tests/test_gitlab_example.py` asserts that only `deploy-production` declares `id_tokens`, its audience is
  `sts.amazonaws.com`, it is manual on the default branch, it needs the build and scan jobs, every image is pinned
  by digest, every job has a timeout, and no AWS key variable appears in the file.

## Notes

- Threat cases for the GitHub subject: [docs/threat-notes.md](../threat-notes.md).
- GitLab documents the ID token claims and the AWS setup in its CI/CD documentation on OpenID Connect.
