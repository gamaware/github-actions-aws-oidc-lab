"""Hardening rules for the GitHub Actions workflows, checked offline.

actionlint and zizmor check syntax and known-bad patterns; these tests pin the
rules the trust model depends on (docs/threat-notes.md).
"""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOWS = sorted((Path(__file__).resolve().parents[1] / ".github" / "workflows").glob("*.yml"))
SHA_PIN = re.compile(r"^[^@]+@[0-9a-f]{40}$")
# Reusable workflows from the shared repository are called by branch until
# the re-pin pass (CHANGELOG, Unreleased).
SHARED = re.compile(r"^gamaware/\.github/\.github/workflows/[a-z-]+\.yml@main$")


def load(path):
    data = yaml.safe_load(path.read_text())
    # PyYAML reads the bare key `on` as the boolean True.
    data["on"] = data.pop(True, data.get("on"))
    return data


@pytest.fixture(params=WORKFLOWS, ids=lambda p: p.name)
def workflow(request):
    return request.param.name, load(request.param)


def triggers(wf):
    on = wf["on"]
    return set(on) if isinstance(on, dict | list) else {on}


def test_workflows_exist():
    assert {p.name for p in WORKFLOWS} >= {"ci.yml", "deploy.yml", "plan.yml"}


def test_default_permissions_are_empty(workflow):
    _, wf = workflow
    assert wf["permissions"] == {}


def test_no_pull_request_target(workflow):
    _, wf = workflow
    assert "pull_request_target" not in triggers(wf)


def test_every_job_has_a_timeout_or_calls_a_reusable_workflow(workflow):
    _, wf = workflow
    jobs = wf["jobs"].items()
    assert [n for n, job in jobs if "timeout-minutes" not in job and "uses" not in job] == []


def test_actions_are_pinned(workflow):
    _, wf = workflow
    unpinned = []
    for job in wf["jobs"].values():
        if "uses" in job and not SHARED.match(job["uses"]):
            unpinned.append(job["uses"])
        for step in job.get("steps", []):
            uses = step.get("uses")
            if uses and not uses.startswith("./") and not SHA_PIN.match(uses):
                unpinned.append(uses)
    assert unpinned == []


def test_only_plan_may_request_an_id_token_on_pull_requests(workflow):
    name, wf = workflow
    if "pull_request" not in triggers(wf) or name == "plan.yml":
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
