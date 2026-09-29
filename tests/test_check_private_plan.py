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


BLOCK_KEYS = ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets")
DENY_INSECURE = json.dumps(
    {
        "Statement": [
            {
                "Effect": "Deny",
                "Principal": "*",
                "Action": "s3:*",
                "Condition": {"Bool": {"aws:SecureTransport": "false"}},
            }
        ]
    }
)
ACCOUNT_PULL = json.dumps(
    {"Statement": [{"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::111122223333:root"}, "Action": "ecr:*"}]}
)
OPEN_READ = json.dumps({"Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject"}]})
ORG_READ = json.dumps(
    {
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Condition": {"StringEquals": {"aws:PrincipalOrgID": "o-exampleorgid"}},
            }
        ]
    }
)
TLS_ONLY_READ = json.dumps(
    {
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Condition": {"Bool": {"aws:SecureTransport": "true"}},
            }
        ]
    }
)
NOT_ACCOUNT_READ = json.dumps(
    {
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Condition": {"StringNotEquals": {"aws:PrincipalAccount": "111122223333"}},
            }
        ]
    }
)


def allow_anyone(condition):
    """An Allow to any principal for s3:GetObject, limited only by the given Condition."""
    statement = {"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Condition": condition}
    return json.dumps({"Statement": [statement]})


ORG_PATHS_READ = allow_anyone(
    {
        "ForAllValues:StringEquals": {"aws:PrincipalOrgPaths": ["o-exampleorgid/r-ab12/ou-ab12-11111111/"]},
        "Null": {"aws:PrincipalOrgPaths": "false"},
    }
)
ANONYMOUS_READ = allow_anyone({"StringEquals": {"aws:PrincipalAccount": "anonymous"}})
ANONYMOUS_IN_LIST_READ = allow_anyone({"StringEquals": {"aws:PrincipalAccount": ["111122223333", "Anonymous"]}})
WILDCARD_ACCOUNT_READ = allow_anyone({"StringLike": {"aws:PrincipalAccount": "*"}})
VARIABLE_ACCOUNT_READ = allow_anyone({"StringEquals": {"aws:PrincipalAccount": "${aws:PrincipalAccount}"}})
VARIABLE_ARN_READ = allow_anyone({"ArnEquals": {"aws:PrincipalArn": "arn:aws:iam::${aws:PrincipalAccount}:root"}})
VARIABLE_IN_LIST_READ = allow_anyone({"StringEquals": {"aws:SourceAccount": ["111122223333", "${aws:SourceAccount}"]}})
WILDCARD_ARN_READ = allow_anyone({"ArnLike": {"aws:PrincipalArn": "arn:aws:iam::?????????????:*"}})
EMPTY_VALUES_READ = allow_anyone({"StringEquals": {"aws:PrincipalOrgID": []}})
BARE_FOR_ALL_VALUES_READ = allow_anyone(
    {"ForAllValues:StringEquals": {"aws:PrincipalOrgPaths": ["o-exampleorgid/r-ab12/ou-ab12-11111111/"]}}
)
FOR_ALL_VALUES_OPTIONAL_READ = allow_anyone(
    {
        "ForAllValues:StringEquals": {"aws:PrincipalOrgPaths": ["o-exampleorgid/r-ab12/ou-ab12-11111111/"]},
        "Null": {"aws:PrincipalOrgPaths": "true"},
    }
)
OPEN_PULL = json.dumps({"Statement": {"Effect": "Allow", "Principal": {"AWS": ["*"]}, "Action": "ecr:BatchGetImage"}})
OPEN_SERVICE_PULL = json.dumps(
    {"Statement": {"Effect": "Allow", "Principal": {"Service": "*"}, "Action": "ecr:BatchGetImage"}}
)
OPEN_FEDERATED_READ = json.dumps(
    {"Statement": [{"Effect": "Allow", "Principal": {"Federated": ["*"]}, "Action": "s3:GetObject"}]}
)

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
    ("aws_s3_bucket_public_access_block", "b", dict.fromkeys(BLOCK_KEYS, True), None),
    ("aws_s3_bucket_policy", "tls", {"policy": DENY_INSECURE}, None),
    ("aws_ecr_repository_policy", "pull", {"policy": ACCOUNT_PULL}, None),
    ("aws_s3_bucket_policy", "org", {"policy": ORG_READ}, None),
    ("aws_s3_bucket_policy", "org_paths", {"policy": ORG_PATHS_READ}, None),
    ("aws_route_table", "empty", {"route": []}, {"route": []}),
    (
        "aws_route_table",
        "transit",
        {"route": [{"cidr_block": "10.1.0.0/16"}]},
        {"route": [{"transit_gateway_id": True}]},
    ),
)


class PrivatePlan(unittest.TestCase):
    def test_private_plan_passes(self):
        assert check.violations(PRIVATE) == []

    def test_destroyed_and_data_resources_are_ignored(self):
        doc = plan(("aws_internet_gateway", "old", None, None))
        doc["resource_changes"].append(
            {"address": "data.aws_lb.x", "mode": "data", "type": "aws_lb", "change": {"after": {"internal": False}}}
        )
        assert check.violations(doc) == []


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
        "Route 53 hosted zone": ("aws_route53_zone", {"name": "example.com"}, None),
        "Route 53 record": ("aws_route53_record", {"type": "A"}, None),
        "Route 53 health check": ("aws_route53_health_check", {"type": "HTTPS"}, None),
        "public EKS endpoint": ("aws_eks_cluster", {"vpc_config": [{"endpoint_public_access": True}]}, None),
        "public S3 bucket policy": ("aws_s3_bucket_policy", {"policy": OPEN_READ}, None),
        "public policy with a transport condition": ("aws_s3_bucket_policy", {"policy": TLS_ONLY_READ}, None),
        "public policy with a negated condition": ("aws_s3_bucket_policy", {"policy": NOT_ACCOUNT_READ}, None),
        "public policy for anonymous callers": ("aws_s3_bucket_policy", {"policy": ANONYMOUS_READ}, None),
        "public policy listing anonymous": ("aws_s3_bucket_policy", {"policy": ANONYMOUS_IN_LIST_READ}, None),
        "public policy with a wildcard account": ("aws_s3_bucket_policy", {"policy": WILDCARD_ACCOUNT_READ}, None),
        "public policy with a policy variable": ("aws_s3_bucket_policy", {"policy": VARIABLE_ACCOUNT_READ}, None),
        "public policy with a policy variable in an ARN": ("aws_s3_bucket_policy", {"policy": VARIABLE_ARN_READ}, None),
        "public policy listing a policy variable": ("aws_s3_bucket_policy", {"policy": VARIABLE_IN_LIST_READ}, None),
        "public policy with a wildcard ARN": ("aws_s3_bucket_policy", {"policy": WILDCARD_ARN_READ}, None),
        "public policy with no condition values": ("aws_s3_bucket_policy", {"policy": EMPTY_VALUES_READ}, None),
        "public policy with bare ForAllValues": ("aws_s3_bucket_policy", {"policy": BARE_FOR_ALL_VALUES_READ}, None),
        "public policy with optional ForAllValues key": (
            "aws_s3_bucket_policy",
            {"policy": FOR_ALL_VALUES_OPTIONAL_READ},
            None,
        ),
        "ECS public IP unknown until apply": (
            "aws_ecs_service",
            {"network_configuration": [{"subnets": ["subnet-1"]}]},
            {"network_configuration": [{"assign_public_ip": True}]},
        ),
        "ECS network unknown until apply": ("aws_ecs_service", {}, {"network_configuration": True}),
        "routes unknown until apply": ("aws_route_table", {}, {"route": True}),
        "route destination unknown until apply": (
            "aws_route",
            {"gateway_id": "igw-1"},
            {"destination_cidr_block": True},
        ),
        "inline route destination unknown until apply": (
            "aws_route_table",
            {"route": [{}]},
            {"route": [{"cidr_block": True, "gateway_id": True}]},
        ),
        "route list unknown until apply": ("aws_route_table", {"route": []}, {"route": [{"gateway_id": True}]}),
        "unknown route next to a known one": (
            "aws_route_table",
            {"route": [{"cidr_block": "10.1.0.0/16", "transit_gateway_id": "tgw-1"}]},
            {"route": [{}, True]},
        ),
        "whole route unknown next to a known one": (
            "aws_route_table",
            {"route": [{"cidr_block": "10.1.0.0/16", "transit_gateway_id": "tgw-1"}, None]},
            {"route": [{}, True]},
        ),
        "inline route with unknown destination to IGW": (
            "aws_route_table",
            {"route": [{"cidr_block": "10.1.0.0/16", "transit_gateway_id": "tgw-1"}, {"gateway_id": "igw-1"}]},
            {"route": [{}, {"cidr_block": True}]},
        ),
        "route with unknown destination to NAT": (
            "aws_route",
            {"nat_gateway_id": "nat-1"},
            {"destination_cidr_block": True},
        ),
        "public policy for any service": ("aws_ecr_repository_policy", {"policy": OPEN_SERVICE_PULL}, None),
        "public policy for any federated principal": ("aws_s3_bucket_policy", {"policy": OPEN_FEDERATED_READ}, None),
        "public ECR policy": ("aws_ecr_repository_policy", {"policy": OPEN_PULL}, None),
        "ECR Public repository": ("aws_ecrpublic_repository", {"repository_name": "x"}, None),
        "S3 website": ("aws_s3_bucket_website_configuration", {}, None),
        "weak public access block": ("aws_s3_bucket_public_access_block", {"block_public_policy": False}, None),
        "public-read ACL": ("aws_s3_bucket_acl", {"acl": "public-read"}, None),
        "regional REST API": ("aws_api_gateway_rest_api", {"endpoint_configuration": [{"types": ["REGIONAL"]}]}, None),
    }

    def test_each_internet_facing_resource_is_refused(self):
        for label, (rtype, after, unknown) in self.CASES.items():
            with self.subTest(label):
                found = check.violations(plan((rtype, "x", after, unknown)))
                assert len(found) == 1, found
                assert found[0].startswith(f"{rtype}.x: "), found


def configured(doc, resources, module_calls=None):
    """Add a configuration block, as terraform show -json writes it, to a plan built with plan()."""
    root = {"resources": [{"address": address, "expressions": expressions} for address, expressions in resources]}
    if module_calls:
        root["module_calls"] = module_calls
    doc["configuration"] = {"root_module": root}
    return doc


VPC_ID = {"vpc_id": {"references": ["aws_vpc.main.id", "aws_vpc.main"]}}


class ComputedRoutes(unittest.TestCase):
    """An initial plan marks route = unknown on a table without route blocks; only configured routes are refused."""

    def test_table_without_route_blocks_passes(self):
        doc = plan(("aws_route_table", "private", {"vpc_id": None}, {"route": True, "vpc_id": True}))
        assert check.violations(configured(doc, [("aws_route_table.private", VPC_ID)])) == []

    def test_table_without_route_blocks_in_a_module_passes(self):
        doc = plan()
        doc["resource_changes"].append(
            {
                "address": 'module.vpc[0].aws_default_route_table.this["a"]',
                "module_address": "module.vpc[0]",
                "mode": "managed",
                "type": "aws_default_route_table",
                "name": "this",
                "change": {"actions": ["create"], "after": {}, "after_unknown": {"route": True}},
            }
        )
        module = {"module": {"resources": [{"address": "aws_default_route_table.this", "expressions": VPC_ID}]}}
        assert check.violations(configured(doc, [], {"vpc": module})) == []

    def test_empty_route_list_passes(self):
        doc = plan(("aws_route_table", "private", {}, {"route": True}))
        route = {"route": {"constant_value": []}}
        assert check.violations(configured(doc, [("aws_route_table.private", {**VPC_ID, **route})])) == []

    def test_private_route_resource_with_unknown_gateway_passes(self):
        doc = plan(
            ("aws_route_table", "private", {}, {"route": True}),
            ("aws_route", "tgw", {"destination_cidr_block": "10.0.0.0/8"}, {"transit_gateway_id": True}),
        )
        table_id = {"route_table_id": {"references": ["aws_route_table.private.id", "aws_route_table.private"]}}
        resources = [("aws_route_table.private", VPC_ID), ("aws_route.tgw", table_id)]
        assert check.violations(configured(doc, resources)) == []

    def test_unknown_route_blocks_are_refused(self):
        doc = plan(("aws_route_table", "private", {}, {"route": True}))
        route = {"route": {"references": ["local.routes"]}}
        found = check.violations(configured(doc, [("aws_route_table.private", {**VPC_ID, **route})]))
        assert found == ["aws_route_table.private: routes are unknown until apply"], found

    def test_unknown_route_resource_on_the_table_is_refused(self):
        doc = plan(
            ("aws_route_table", "private", {}, {"route": True}),
            ("aws_route", "egress", {}, {"destination_cidr_block": True, "gateway_id": True}),
        )
        table_id = {"route_table_id": {"references": ["aws_route_table.private[0].id", "aws_route_table.private"]}}
        resources = [("aws_route_table.private", VPC_ID), ("aws_route.egress", table_id)]
        found = check.violations(configured(doc, resources))
        assert "aws_route_table.private: routes are unknown until apply" in found, found
        assert "aws_route.egress: default route to the internet" in found, found

    def test_unknown_routes_without_a_configuration_block_are_refused(self):
        found = check.violations(plan(("aws_route_table", "private", {}, {"route": True})))
        assert found == ["aws_route_table.private: routes are unknown until apply"], found


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
        assert code == 0
        assert "private-only" in out

    def test_exit_one_and_names_each_violation(self):
        code, _, err = self.run_main(plan(("aws_lb", "app", {"internal": False}, None)))
        assert code == 1
        assert "INTERNET-FACING aws_lb.app" in err

    def test_exit_two_on_input_that_is_not_a_plan(self):
        code, _, err = self.run_main({"values": {}})
        assert code == 2
        assert "not the JSON form" in err


if __name__ == "__main__":
    unittest.main()
