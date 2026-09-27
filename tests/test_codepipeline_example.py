"""Properties of the CodePipeline buildspecs, checked offline.

CodeBuild does not run here, so these tests pin what the pipeline's trust in
the image depends on: tests and the Trivy gate run before the push, a failed
phase stops the build, Trivy is checked against a pinned checksum, and the
deploy receives the image by digest. The Terraform side is asserted in
examples/codepipeline/terraform/tests/codepipeline.tftest.hcl.
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples" / "codepipeline"
BUILD_FILE = EXAMPLE / "buildspec-build.yml"
VERIFY_FILE = EXAMPLE / "buildspec-verify.yml"


@pytest.fixture(scope="module")
def build():
    return yaml.safe_load(BUILD_FILE.read_text())


@pytest.fixture(scope="module")
def verify():
    return yaml.safe_load(VERIFY_FILE.read_text())


def commands(spec, phase):
    return spec["phases"][phase]["commands"]


def position(lines, needle):
    matches = [i for i, line in enumerate(lines) if needle in line]
    assert matches, f"{needle!r} not found"
    return matches[0]


def test_every_phase_aborts_on_failure(build, verify):
    for spec in (build, verify):
        assert spec["version"] == 0.2
        assert spec["env"]["shell"] == "bash"
        for name, phase in spec["phases"].items():
            assert phase.get("on-failure") == "ABORT", name


def test_nothing_runs_in_post_build(build, verify):
    # CodeBuild runs post_build even after a failed build phase.
    assert "post_build" not in build["phases"]
    assert "post_build" not in verify["phases"]


def test_trivy_is_pinned_and_checksum_verified(build):
    variables = build["env"]["variables"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", variables["TRIVY_VERSION"])
    assert re.fullmatch(r"[0-9a-f]{64}", variables["TRIVY_SHA256"])
    install = commands(build, "install")
    assert position(install, "sha256sum --check --strict") < position(install, "tar -xzf trivy")


def test_tests_and_trivy_gate_run_before_the_push(build):
    assert any("pytest" in line for line in commands(build, "pre_build"))
    steps = commands(build, "build")
    scan = steps[position(steps, "trivy image")]
    assert "--severity HIGH,CRITICAL" in scan
    assert "--ignore-unfixed" in scan
    assert "--exit-code 1" in scan
    assert position(steps, "docker build") < position(steps, "trivy image")
    assert position(steps, "trivy image") < position(steps, "docker push")


def test_deploy_gets_the_image_by_digest(build):
    steps = commands(build, "build")
    assert build["env"]["exported-variables"] == ["IMAGE_DIGEST", "IMAGE_URI"]
    assert position(steps, "docker push") < position(steps, "IMAGE_URI=")
    assert "@sha256:" in steps[position(steps, "IMAGE_URI=")]
    assert "sha256:[0-9a-f]{64}" in steps[position(steps, 'IMAGE_DIGEST" =~')]
    assert "imagedefinitions.json" in steps[position(steps, "printf")]
    assert build["artifacts"]["files"] == ["imagedefinitions.json"]


def test_verify_runs_the_shared_script_on_the_built_image(verify):
    steps = commands(verify, "build")
    assert position(steps, '"$DEPLOYED_IMAGE" == "$EXPECTED_IMAGE_URI"') < position(
        steps, "bash scripts/verify-deployment.sh"
    )


def test_no_static_aws_credentials():
    for path in (BUILD_FILE, VERIFY_FILE):
        text = path.read_text()
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
            assert name not in text
        assert not re.search(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b", text)
