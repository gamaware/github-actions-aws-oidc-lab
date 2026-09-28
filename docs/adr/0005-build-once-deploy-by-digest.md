# 0005. Build once, scan what ships, deploy by digest, verify after

## Status

Accepted. Replaces the first version's single job that built, pushed and deployed a tag.

## Context

The first version built the image inside the deploy job, pushed it with a tag, and pointed the task definition at
that tag. Three gaps:

1. The image scanned in pull request CI was a different build from the one deployed. Base image layers or package
   versions can change between the two builds.
2. The task definition referenced a tag. Tags in this ECR repository are immutable, but a digest is what the
   registry actually serves, and it is what a signature or attestation names.
3. "Service stable" was the only success signal. With the circuit breaker on, a failed rollout rolls back and the
   service becomes stable again on the old revision.

## Decision

`deploy.yml` has two jobs:

- **build** (no AWS access): build the image once with BuildKit into an OCI archive and read its manifest digest;
  gate it with Trivy (fixable HIGH and CRITICAL); generate a CycloneDX SBOM; sign a build-provenance attestation
  and an SBOM attestation for that digest with `actions/attest-build-provenance` and `actions/attest-sbom`; pass
  the archive to the next job as an artifact.
- **deploy** (`environment: production`, after the reviewer approves): push the archive with
  `skopeo copy --preserve-digests`; fail if the registry digest differs from the built digest; verify the
  attestation with `gh attestation verify`; render the task definition with `image@sha256:<digest>`; deploy and
  wait for stability; then run `scripts/verify-deployment.sh`, which checks that the PRIMARY deployment is the new
  revision with a completed rollout, that the desired number of tasks are RUNNING and HEALTHY on that revision and
  digest, and, when `APP_URL` is set, that `/health` answers and `/` reports the commit SHA.

## Consequences

- The bytes that ECS runs are the bytes Trivy scanned and the attestation describes.
- A rollback now fails the workflow instead of passing silently.
- The image travels between jobs as an artifact (tens of MB, kept for one day).
- The deploy role gained `ecs:ListTasks` (conditioned on one cluster) and `ecs:DescribeTasks` (tasks in one
  cluster) for the verification step.
- ECS does not verify the attestation itself. Verification happens in the pipeline, before the task definition is
  registered. Enforcing signatures at run time would need an admission control such as a Lambda hook or a
  different platform, and is out of scope.
- When `desired_count` is 0, the verification step warns and stops after the deployment checks, because no task
  runs the new revision.

## Compliance

- Automated: the deploy job fails if the pushed digest differs from the built digest, if the attestation does not
  verify for this repository and workflow, or if `verify-deployment.sh` exits non-zero. The Trivy gate in `build`
  fails the run before anything reaches AWS.
- The job summary of every deploy records the commit, the `image@digest`, the task definition ARN and the run URL.
  GitHub also records a deployment on the `production` environment for each run.

## Notes

- Related: [ADR 0006](0006-security-gates.md) for the pull request gates.
- Verify an image by hand: `gh attestation verify oci://<repository-url>@sha256:<digest> --repo OWNER/REPO`.
