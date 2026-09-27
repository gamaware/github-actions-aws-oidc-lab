# Architecture Decision Records

Each record follows the format in *Fundamentals of Software Architecture* (2nd edition): title, status, context,
decision, consequences, compliance (how the decision is checked, automated where possible) and notes.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-exact-subject-matching.md) | Match OIDC claims with StringEquals, never StringLike | Accepted |
| [0002](0002-environment-subject-only.md) | Trust only the environment subject, not the branch subject | Accepted |
| [0003](0003-no-task-role.md) | No ECS task role; the execution role only pulls and logs | Accepted |
| [0004](0004-one-role-per-deploy-target.md) | One OIDC role per deploy target | Accepted |
| [0005](0005-build-once-deploy-by-digest.md) | Build once, scan what ships, deploy by digest, verify after | Accepted |
| [0006](0006-security-gates.md) | Semgrep, Trivy and Checkov as required checks, with SARIF in code scanning | Accepted |
| [0007](0007-read-only-plan-role.md) | A separate, optional, read-only role for terraform plan on pull requests | Accepted |
| [0008](0008-offline-policy-tests.md) | Test IAM policies offline with terraform test and a mocked provider | Accepted |
| [0009](0009-gitlab-ci-example.md) | Show the GitLab CI equivalent as a tested example, bound to the protected branch | Accepted |
| [0010](0010-github-actions-vs-codepipeline.md) | GitHub Actions vs CodePipeline: when to use each | Accepted |

To add a record, copy the section headings of an existing one, take the next number, and link it here. A decision
that changes an accepted one gets a new record that says which one it supersedes.
