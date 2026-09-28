#!/usr/bin/env python3
"""Refuse a Terraform plan that would make anything reachable from the internet.

Live tests run private-only. The live-test scripts call this on the JSON form of the plan before any apply:

    terraform show -json plan.bin | python3 scripts/check_private_plan.py
    python3 scripts/check_private_plan.py plan.json

Exit status 0 when the plan is private-only; 1, with one line per violation, when it is not; 2 when the input is not
a Terraform plan. Standard library only, so it runs before any project tooling is installed.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterator
from typing import Any

WORLD = {"0.0.0.0/0", "::/0"}

# Resource types that exist only to reach, or be reached from, the internet.
FORBIDDEN_TYPES = {
    "aws_internet_gateway": "internet gateway",
    "aws_internet_gateway_attachment": "internet gateway attachment",
    "aws_egress_only_internet_gateway": "egress-only internet gateway",
    "aws_eip": "Elastic IP address",
    "aws_eip_association": "Elastic IP association",
    "aws_lambda_function_url": "public Lambda function URL",
    "aws_cloudfront_distribution": "CloudFront distribution",
    "aws_globalaccelerator_accelerator": "Global Accelerator",
    "aws_apigatewayv2_api": "API Gateway HTTP/WebSocket API",
    "aws_ecrpublic_repository": "ECR Public repository",
    "aws_s3_bucket_website_configuration": "S3 static website endpoint",
}

PUBLIC_ACLS = {"public-read", "public-read-write", "authenticated-read"}

# Resource policies that could grant access to anyone: an Allow to "*" without a Condition is refused.
POLICY_TYPES = {"aws_s3_bucket_policy", "aws_ecr_repository_policy", "aws_ecrpublic_repository_policy"}

PUBLICLY_ACCESSIBLE_TYPES = {
    "aws_db_instance",
    "aws_rds_cluster_instance",
    "aws_dms_replication_instance",
    "aws_redshift_cluster",
}


def _resources(plan: dict[str, Any]) -> Iterator[tuple[str, str, dict[str, Any], dict[str, Any]]]:
    """Yield (address, type, after, after_unknown) for every managed resource the plan creates or keeps."""
    for change in plan.get("resource_changes", []):
        if change.get("mode", "managed") != "managed":
            continue
        body = change.get("change", {})
        after = body.get("after")
        if after is None:  # being destroyed
            continue
        unknown = body.get("after_unknown") or {}
        yield change["address"], change["type"], after, unknown if isinstance(unknown, dict) else {}


def _world(values: Any) -> bool:
    return any(v in WORLD for v in values or [])


def _default_route_via_gateway(route: dict[str, Any], unknown: dict[str, Any]) -> bool:
    """A default route (0.0.0.0/0 or ::/0) through an internet, NAT or egress-only gateway."""
    keys = ("cidr_block", "ipv6_cidr_block", "destination_cidr_block", "destination_ipv6_cidr_block")
    if not any(route.get(key) in WORLD for key in keys):
        return False
    return any(route.get(key) or unknown.get(key) for key in ("gateway_id", "nat_gateway_id", "egress_only_gateway_id"))


def _allows_anyone(policy: Any) -> bool:
    """True when a policy document has an Allow statement for any principal ("*") and no Condition."""
    if not isinstance(policy, str) or not policy:
        return False
    try:
        document = json.loads(policy)
    except json.JSONDecodeError:
        return False
    statements = document.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    for statement in statements:
        principal = statement.get("Principal")
        anyone = principal == "*" or (isinstance(principal, dict) and "*" in _as_list(principal.get("AWS")))
        if statement.get("Effect") == "Allow" and anyone and not statement.get("Condition"):
            return True
    return False


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


def violations(plan: dict[str, Any]) -> list[str]:
    found: list[str] = []
    for address, rtype, after, unknown in _resources(plan):
        if rtype in FORBIDDEN_TYPES:
            found.append(f"{address}: {FORBIDDEN_TYPES[rtype]} is internet-facing")
        elif rtype.startswith("aws_route53"):
            found.append(f"{address}: Route 53 is not used in live tests")
        elif rtype == "aws_eks_cluster" and any(
            cfg.get("endpoint_public_access") is not False for cfg in after.get("vpc_config") or [{}]
        ):
            found.append(f"{address}: EKS API endpoint must set endpoint_public_access = false")
        elif rtype == "aws_nat_gateway" and after.get("connectivity_type", "public") != "private":
            found.append(f"{address}: public NAT gateway routes workloads to the internet")
        elif rtype in ("aws_lb", "aws_alb", "aws_elb") and after.get("internal") is not True:
            found.append(f"{address}: load balancer must set internal = true")
        elif rtype in ("aws_security_group", "aws_default_security_group"):
            for rule in after.get("ingress") or []:
                if _world(rule.get("cidr_blocks")) or _world(rule.get("ipv6_cidr_blocks")):
                    found.append(f"{address}: ingress from 0.0.0.0/0 or ::/0 on port {rule.get('from_port')}")
        elif rtype == "aws_security_group_rule" and after.get("type") == "ingress":
            if _world(after.get("cidr_blocks")) or _world(after.get("ipv6_cidr_blocks")):
                found.append(f"{address}: ingress from 0.0.0.0/0 or ::/0 on port {after.get('from_port')}")
        elif rtype == "aws_vpc_security_group_ingress_rule":
            if after.get("cidr_ipv4") in WORLD or after.get("cidr_ipv6") in WORLD:
                found.append(f"{address}: ingress from 0.0.0.0/0 or ::/0 on port {after.get('from_port')}")
        elif rtype == "aws_ecs_service":
            for net in after.get("network_configuration") or []:
                if net.get("assign_public_ip"):
                    found.append(f"{address}: ECS tasks must run with assign_public_ip = false")
        elif rtype == "aws_subnet" and after.get("map_public_ip_on_launch"):
            found.append(f"{address}: subnet maps public IP addresses on launch")
        elif rtype == "aws_instance" and after.get("associate_public_ip_address"):
            found.append(f"{address}: instance gets a public IP address")
        elif rtype in PUBLICLY_ACCESSIBLE_TYPES and after.get("publicly_accessible"):
            found.append(f"{address}: publicly_accessible must be false")
        elif rtype == "aws_route" and _default_route_via_gateway(after, unknown):
            found.append(f"{address}: default route to the internet")
        elif rtype in ("aws_route_table", "aws_default_route_table"):
            routes_unknown = unknown.get("route")
            for i, route in enumerate(after.get("route") or []):
                route_unknown = (
                    routes_unknown[i] if isinstance(routes_unknown, list) and i < len(routes_unknown) else {}
                )
                if _default_route_via_gateway(route, route_unknown if isinstance(route_unknown, dict) else {}):
                    found.append(f"{address}: default route to the internet")
        elif rtype in POLICY_TYPES and _allows_anyone(after.get("policy")):
            found.append(f"{address}: resource policy allows any principal")
        elif rtype in ("aws_s3_bucket_public_access_block", "aws_s3_account_public_access_block"):
            keys = ("block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets")
            if not all(after.get(key) is True for key in keys):
                found.append(f"{address}: all four S3 public access block settings must be true")
        elif rtype == "aws_s3_bucket_acl" and after.get("acl") in PUBLIC_ACLS:
            found.append(f"{address}: public S3 bucket ACL {after.get('acl')}")
        elif rtype == "aws_api_gateway_rest_api":
            types = [t for cfg in after.get("endpoint_configuration") or [] for t in cfg.get("types") or []]
            if types != ["PRIVATE"]:
                found.append(f"{address}: REST API endpoint type must be PRIVATE")
    return found


def main(argv: list[str]) -> int:
    try:
        if len(argv) > 1:
            with open(argv[1], encoding="utf-8") as handle:
                plan = json.load(handle)
        else:
            plan = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"check_private_plan: cannot read the plan: {exc}", file=sys.stderr)
        return 2
    if not isinstance(plan, dict) or "resource_changes" not in plan:
        print("check_private_plan: input is not the JSON form of a Terraform plan", file=sys.stderr)
        return 2
    found = violations(plan)
    for line in found:
        print(f"INTERNET-FACING {line}", file=sys.stderr)
    if found:
        print(f"check_private_plan: {len(found)} internet-facing resource(s); live test refused", file=sys.stderr)
        return 1
    print("check_private_plan: plan is private-only")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
