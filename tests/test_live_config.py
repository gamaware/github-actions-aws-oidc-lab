"""Static guards for the private-only live tests (docs/live-test.md).

tests/live/terraform/tests/private_only.tftest.hcl plans the live network and the deploy target with a mocked
provider. These tests cover what a plan-time assertion cannot: resource types that must not appear in the live
network root at all, and how the live scripts pass settings and apply plans.
"""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIVE = ROOT / "tests" / "live"
SCRIPTS = [ROOT / "scripts" / "test-live.sh", ROOT / "scripts" / "test-live-codepipeline.sh"]

# Resource types a private-only network never needs.
FORBIDDEN_IN_NETWORK = {
    "aws_internet_gateway",
    "aws_internet_gateway_attachment",
    "aws_egress_only_internet_gateway",
    "aws_nat_gateway",
    "aws_eip",
    "aws_route",
    "aws_lb",
    "aws_alb",
    "aws_elb",
}
RESOURCE = re.compile(r'^resource\s+"([a-z0-9_]+)"', re.MULTILINE)


def test_the_live_network_declares_no_internet_path():
    declared = {m for tf in (LIVE / "terraform").glob("*.tf") for m in RESOURCE.findall(tf.read_text())}
    assert declared, "the live network root declares no resources"
    assert declared & FORBIDDEN_IN_NETWORK == set()


def test_deploy_target_settings_are_private():
    settings = json.loads((LIVE / "deploy-target.tfvars.json").read_text())
    assert settings == {"assign_public_ip": False, "ingress_cidr_blocks": []}


@pytest.fixture(params=SCRIPTS, ids=lambda p: p.name)
def script(request):
    return request.param.read_text()


def test_script_uses_the_private_settings_file_and_never_overrides_it(script):
    assert '-var-file="$TARGET_VARS_FILE"' in script
    assert "assign_public_ip=" not in script
    assert "ingress_cidr_blocks=" not in script


def test_script_never_looks_up_the_default_vpc(script):
    assert "isDefault" not in script
    assert "VPC_ID" not in script and "SUBNET_ID" not in script


def test_script_applies_only_plans_the_preflight_checked(script):
    applies = [line for line in script.splitlines() if re.search(r"\bapply\b", line) and "apply_checked" not in line]
    assert [line for line in applies if not line.lstrip().startswith("#")] == []
    assert 'python3 "$REPO_ROOT/scripts/check_private_plan.py"' in script
    calls = re.findall(r"^(preflight|apply_checked) \"\$(\w+)_ROOT\" (\w+)", script, re.MULTILINE)
    assert calls, "no pre-flight or apply calls found"
    # Every apply follows the pre-flight of the same root and label.
    for i, (kind, root, label) in enumerate(calls):
        if kind == "apply_checked":
            assert i > 0 and calls[i - 1] == ("preflight", root, label)
