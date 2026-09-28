"""Security properties of the GitLab CI example, checked offline.

The pipeline cannot run here, so these tests pin the properties the trust
model depends on: one job with an ID token, the right audience, manual deploy
from the default branch only, images pinned by digest, and no AWS keys.
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PIPELINE_FILE = ROOT / "examples" / "gitlab-ci" / ".gitlab-ci.yml"
RESERVED = {"workflow", "stages", "default", "variables", "include"}
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")


@pytest.fixture(scope="module")
def pipeline():
    return yaml.safe_load(PIPELINE_FILE.read_text())


@pytest.fixture(scope="module")
def jobs(pipeline):
    return {name: job for name, job in pipeline.items() if name not in RESERVED}


def image_refs(job):
    refs = []
    for item in [job.get("image"), *job.get("services", [])]:
        if item is not None:
            refs.append(item["name"] if isinstance(item, dict) else item)
    return refs


def test_no_defaults_or_templates_can_hide_job_settings(pipeline, jobs):
    # A token or an image under `default:`, or in a template pulled in with
    # `extends:`, would apply to jobs these tests look at one by one.
    assert "id_tokens" not in pipeline.get("default", {})
    assert "image" not in pipeline.get("default", {})
    assert [name for name, job in jobs.items() if "extends" in job or name.startswith(".")] == []


def test_only_the_deploy_job_can_get_an_id_token(jobs):
    assert [name for name, job in jobs.items() if "id_tokens" in job] == ["deploy-production"]


def test_id_token_audience_is_sts(jobs):
    tokens = jobs["deploy-production"]["id_tokens"]
    assert tokens == {"AWS_ID_TOKEN": {"aud": "sts.amazonaws.com"}}


def test_deploy_is_manual_on_the_default_branch_only(jobs):
    deploy = jobs["deploy-production"]
    assert deploy["rules"] == [{"if": "$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH", "when": "manual"}]
    assert deploy["environment"]["name"] == "production"
    assert deploy["resource_group"] == "production"
    assert deploy["interruptible"] is False


def test_deploy_ships_the_scanned_build(jobs):
    assert jobs["scan-image"]["needs"] == ["build-image"]
    assert jobs["deploy-production"]["needs"] == ["build-image", "scan-image"]
    script = "\n".join(jobs["deploy-production"]["script"])
    assert "--preserve-digests oci-archive:image.tar" in script
    assert '"$PUSHED" = "$DIGEST"' in script
    assert "./scripts/verify-deployment.sh" in script


def test_trivy_gate_fails_on_fixable_high_and_critical(jobs):
    script = "\n".join(jobs["scan-image"]["script"])
    assert "--severity HIGH,CRITICAL" in script
    assert "--ignore-unfixed" in script
    assert "--exit-code 1" in script


def test_every_image_is_pinned_by_digest(jobs):
    refs = [ref for job in jobs.values() for ref in image_refs(job)]
    assert refs, "no images found"
    assert [ref for ref in refs if not DIGEST.search(ref)] == []


def test_every_job_has_a_timeout(jobs):
    assert [name for name, job in jobs.items() if "timeout" not in job] == []


def test_no_static_aws_credentials():
    text = PIPELINE_FILE.read_text()
    for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
        assert name not in text
    assert not re.search(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b", text)
