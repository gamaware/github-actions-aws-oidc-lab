"""Tests for scripts/check_private_plan.py, the live-test pre-flight. Standard library unittest; pytest collects it."""

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import ClassVar

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_private_plan.py"
_spec = importlib.util.spec_from_file_location("check_private_plan", SCRIPT)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


def plan(*resources):
    return {
        "format_version": "1.2",
        "resource_changes": [
            {
                "address": f"{rtype}.{name}",
                "mode": "managed",
                "type": rtype,
                "change": {"actions": ["create"], "after": after, "after_unknown": unknown or {}},
            }
            for rtype, name, after, unknown in resources
        ],
    }


PRIVATE = plan(
    ("aws_lb", "app", {"internal": True, "load_balancer_type": "application"}, None),
    ("aws_vpc_security_group_ingress_rule", "alb", {"cidr_ipv4": "10.0.0.0/16", "from_port": 443}, None),
    ("aws_security_group", "task", {"ingress": [{"cidr_blocks": ["10.0.0.0/16"], "from_port": 8080}]}, None),
    ("aws_ecs_service", "app", {"network_configuration": [{"assign_public_ip": False}]}, None),
    ("aws_subnet", "private", {"map_public_ip_on_launch": False}, None),
    ("aws_route", "vpn", {"destination_cidr_block": "192.168.0.0/16"}, {"gateway_id": True}),
    ("aws_db_instance", "db", {"publicly_accessible": False}, None),
    ("aws_nat_gateway", "private", {"connectivity_type": "private"}, None),
    ("aws_vpc_security_group_egress_rule", "https", {"cidr_ipv4": "0.0.0.0/0", "from_port": 443}, None),
)


class PrivatePlan(unittest.TestCase):
    def test_private_plan_passes(self):
        self.assertEqual(check.violations(PRIVATE), [])

    def test_destroyed_and_data_resources_are_ignored(self):
        doc = plan(("aws_internet_gateway", "old", None, None))
        doc["resource_changes"].append(
            {"address": "data.aws_lb.x", "mode": "data", "type": "aws_lb", "change": {"after": {"internal": False}}}
        )
        self.assertEqual(check.violations(doc), [])


class InternetFacing(unittest.TestCase):
    CASES: ClassVar[dict] = {
        "public load balancer": ("aws_lb", {"internal": False}, None),
        "load balancer without internal": ("aws_lb", {}, None),
        "classic load balancer": ("aws_elb", {"internal": False}, None),
        "ipv4 ingress rule": ("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0"}, None),
        "ipv6 ingress rule": ("aws_vpc_security_group_ingress_rule", {"cidr_ipv6": "::/0"}, None),
        "inline ingress": ("aws_security_group", {"ingress": [{"cidr_blocks": ["0.0.0.0/0"]}]}, None),
        "legacy ingress rule": ("aws_security_group_rule", {"type": "ingress", "ipv6_cidr_blocks": ["::/0"]}, None),
        "public ECS task": ("aws_ecs_service", {"network_configuration": [{"assign_public_ip": True}]}, None),
        "internet gateway": ("aws_internet_gateway", {}, None),
        "public NAT gateway": ("aws_nat_gateway", {"connectivity_type": "public"}, None),
        "elastic IP": ("aws_eip", {}, None),
        "default route to IGW": ("aws_route", {"destination_cidr_block": "0.0.0.0/0"}, {"gateway_id": True}),
        "default route to NAT": ("aws_route", {"destination_cidr_block": "0.0.0.0/0", "nat_gateway_id": "nat-1"}, None),
        "inline default route": (
            "aws_route_table",
            {"route": [{"cidr_block": "0.0.0.0/0", "gateway_id": "igw-1"}]},
            None,
        ),
        "public subnet": ("aws_subnet", {"map_public_ip_on_launch": True}, None),
        "public database": ("aws_db_instance", {"publicly_accessible": True}, None),
        "public DMS instance": ("aws_dms_replication_instance", {"publicly_accessible": True}, None),
        "public instance": ("aws_instance", {"associate_public_ip_address": True}, None),
        "function URL": ("aws_lambda_function_url", {"authorization_type": "NONE"}, None),
        "regional REST API": ("aws_api_gateway_rest_api", {"endpoint_configuration": [{"types": ["REGIONAL"]}]}, None),
    }

    def test_each_internet_facing_resource_is_refused(self):
        for label, (rtype, after, unknown) in self.CASES.items():
            with self.subTest(label):
                found = check.violations(plan((rtype, "x", after, unknown)))
                self.assertEqual(len(found), 1, found)
                self.assertTrue(found[0].startswith(f"{rtype}.x: "), found)


class CommandLine(unittest.TestCase):
    def run_main(self, doc):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "plan.json"
        path.write_text(json.dumps(doc), encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = check.main(["check_private_plan.py", str(path)])
        return code, out.getvalue(), err.getvalue()

    def test_exit_zero_on_private_plan(self):
        code, out, _ = self.run_main(PRIVATE)
        self.assertEqual(code, 0)
        self.assertIn("private-only", out)

    def test_exit_one_and_names_each_violation(self):
        code, _, err = self.run_main(plan(("aws_lb", "app", {"internal": False}, None)))
        self.assertEqual(code, 1)
        self.assertIn("INTERNET-FACING aws_lb.app", err)

    def test_exit_two_on_input_that_is_not_a_plan(self):
        code, _, err = self.run_main({"values": {}})
        self.assertEqual(code, 2)
        self.assertIn("not the JSON form", err)


if __name__ == "__main__":
    unittest.main()
