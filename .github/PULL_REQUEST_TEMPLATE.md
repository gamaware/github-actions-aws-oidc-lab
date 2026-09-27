# Pull request

## What and why

<!-- One or two sentences: what changes and the reason. -->

## Checklist

- [ ] The title is a conventional commit (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`, `refactor:`, `test:`).
- [ ] `pre-commit run --all-files` passes.
- [ ] `terraform test` passes in `infra/` if IAM, variables or policies changed.
- [ ] Trust or permission changes are covered by an assertion in `infra/tests/iam.tftest.hcl`.
- [ ] A change to a recorded decision has a new or updated ADR in `docs/adr/`.
- [ ] `docs/threat-notes.md` and the README still match the behavior.
- [ ] `CHANGELOG.md` has an entry under Unreleased.
- [ ] No real account IDs, ARNs, IPs or credentials; placeholders only.
