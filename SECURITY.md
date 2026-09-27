# Security policy

This is a personal lab. It is maintained on a best-effort basis and has no service-level commitment.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: open the **Security** tab of this repository and choose
**Report a vulnerability**. Please do not open a public issue for a security problem.

Useful reports include the file and line, what an attacker could do, and how to reproduce it. Examples in scope:

- a way for a workflow outside the `production` environment to assume the deploy role;
- a permission in the deploy or plan role that reaches beyond the one repository, service or state object;
- a workflow pattern that exposes a token or lets pull request code run with write access.

## Supported versions

Only the `main` branch is supported.

## Supply chain

- Actions are pinned to full commit SHAs and updated by Dependabot with a cooldown.
- The base image is pinned by digest. Semgrep, Trivy and Checkov run as required checks and upload SARIF to code
  scanning ([ADR 0006](docs/adr/0006-security-gates.md)).
- Each deployed image has a build-provenance attestation and an SBOM attestation. Verify one with:

  ```bash
  gh attestation verify oci://YOUR_ECR_REPOSITORY_URL@sha256:DIGEST --repo OWNER/REPO
  ```
