"""Hardening rules for the GitHub Actions workflows, checked offline.

actionlint and zizmor check syntax and known-bad patterns; these tests pin the
rules the trust model depends on (docs/threat-notes.md).
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
# Client-installed examples: not active here, held to the same hardening rules.
EXAMPLES = sorted((ROOT / "examples" / "workflows").glob("*.yml"))
SHA_PIN = re.compile(r"^[^@]+@[0-9a-f]{40}$")


def load(path):
    data = yaml.safe_load(path.read_text())
    # PyYAML reads the bare key `on` as the boolean True.
    data["on"] = data.pop(True, data.get("on"))
    return data


@pytest.fixture(params=WORKFLOWS, ids=lambda p: p.name)
def workflow(request):
    return request.param.name, load(request.param)


@pytest.fixture(params=WORKFLOWS + EXAMPLES, ids=lambda p: str(p.relative_to(ROOT)))
def any_workflow(request):
    return request.param.name, load(request.param)


def triggers(wf):
    on = wf["on"]
    return set(on) if isinstance(on, dict | list) else {on}


def test_workflows_exist():
    assert {p.name for p in WORKFLOWS} >= {"ci.yml", "deploy.yml"}
    assert {p.name for p in EXAMPLES} >= {"plan.yml"}


def test_the_cloud_plan_workflow_is_only_an_example():
    assert "plan.yml" not in {p.name for p in WORKFLOWS}


def test_default_permissions_are_empty(any_workflow):
    _, wf = any_workflow
    assert wf["permissions"] == {}


def test_no_pull_request_target(any_workflow):
    _, wf = any_workflow
    assert "pull_request_target" not in triggers(wf)


def test_every_job_has_a_timeout_or_calls_a_reusable_workflow(any_workflow):
    _, wf = any_workflow
    jobs = wf["jobs"].items()
    assert [n for n, job in jobs if "timeout-minutes" not in job and "uses" not in job] == []


def test_actions_are_pinned(any_workflow):
    _, wf = any_workflow
    unpinned = []
    for job in wf["jobs"].values():
        if "uses" in job and not SHA_PIN.match(job["uses"]):
            unpinned.append(job["uses"])
        for step in job.get("steps", []):
            uses = step.get("uses")
            if uses and not uses.startswith("./") and not SHA_PIN.match(uses):
                unpinned.append(uses)
    assert unpinned == []


def test_no_pull_request_workflow_requests_an_id_token(workflow):
    name, wf = workflow
    if "pull_request" not in triggers(wf):
        return
    for job_name, job in wf["jobs"].items():
        assert (job.get("permissions") or {}).get("id-token") != "write", f"{name}:{job_name}"


def test_deploy_job_is_the_only_one_bound_to_production():
    bound = []
    for path in WORKFLOWS:
        for job_name, job in load(path)["jobs"].items():
            env = job.get("environment")
            env = env.get("name") if isinstance(env, dict) else env
            if env == "production":
                bound.append(f"{path.name}:{job_name}")
    assert bound == ["deploy.yml:deploy"]


def test_deploy_runs_only_on_pushes_to_main():
    wf = load(next(p for p in WORKFLOWS if p.name == "deploy.yml"))
    assert wf["on"] == {"push": {"branches": ["main"]}}
    assert wf["concurrency"]["cancel-in-progress"] is False


def test_deploy_attestations_always_name_a_subject():
    wf = load(next(p for p in WORKFLOWS if p.name == "deploy.yml"))
    build = wf["jobs"]["build"]
    assert build["env"]["SUBJECT_NAME"] == "${{ vars.ECR_REPOSITORY_URL || github.repository }}"
    attest = [s for s in build["steps"] if s.get("uses", "").startswith("actions/attest-")]
    assert len(attest) == 2
    for step in attest:
        assert step["with"]["subject-name"] == "${{ env.SUBJECT_NAME }}"
        assert step["with"]["subject-digest"] == "${{ steps.build.outputs.digest }}"


def test_deploy_job_skips_without_aws_configuration():
    wf = load(next(p for p in WORKFLOWS if p.name == "deploy.yml"))
    condition = wf["jobs"]["deploy"]["if"]
    assert "vars.AWS_ROLE_ARN != ''" in condition
    assert "vars.ECR_REPOSITORY_URL != ''" in condition
