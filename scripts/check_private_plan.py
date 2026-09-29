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
import re
import sys
from collections.abc import Iterator
from typing import Any

WORLD = {"0.0.0.0/0", "::/0"}
ROUTE_DESTINATION_KEYS = ("cidr_block", "ipv6_cidr_block", "destination_cidr_block", "destination_ipv6_cidr_block")
INTERNET_GATEWAY_KEYS = ("gateway_id", "nat_gateway_id", "egress_only_gateway_id")
ROUTE_TABLE_TYPES = ("aws_route_table", "aws_default_route_table")
INSTANCE_KEY = re.compile(r'\[(?:"(?:[^"\\]|\\.)*"|[^\]]*)\]')  # [0] or ["key"] in a resource address

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

# Resource policies that could grant access to anyone: an Allow to "*" is refused unless a Condition limits the
# caller to an account, organization, principal, source resource or VPC.
POLICY_TYPES = {"aws_s3_bucket_policy", "aws_ecr_repository_policy", "aws_ecrpublic_repository_policy"}

# Condition keys that tie a statement to known callers. aws:SecureTransport, aws:SourceIp and similar keys do not:
# anyone on the internet can meet them.
RESTRICTING_CONDITION_KEYS = {
    "aws:principalaccount",
    "aws:principalarn",
    "aws:principalorgid",
    "aws:principalorgpaths",
    "aws:sourceaccount",
    "aws:sourcearn",
    "aws:sourceorgid",
    "aws:sourceorgpaths",
    "aws:sourcevpc",
    "aws:sourcevpce",
}

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
    """A default route (0.0.0.0/0 or ::/0) through an internet, NAT or egress-only gateway.

    A destination known only after apply could be a default route, so it counts as one.
    """
    destination_unknown = any(unknown.get(key) for key in ROUTE_DESTINATION_KEYS)
    if not destination_unknown and not any(route.get(key) in WORLD for key in ROUTE_DESTINATION_KEYS):
        return False
    return any(route.get(key) or unknown.get(key) for key in INTERNET_GATEWAY_KEYS)


def _config_expressions(plan: dict[str, Any]) -> dict[str, dict[str, Any]] | None:
    """Expressions of every resource block in the plan's configuration, keyed by address without instance keys.

    None when the plan has no configuration block: then nothing can be shown to be unconfigured.
    """
    config = plan.get("configuration")
    if not isinstance(config, dict):
        return None
    index: dict[str, dict[str, Any]] = {}
    pending: list[tuple[str, Any]] = [("", config.get("root_module"))]
    while pending:
        prefix, module = pending.pop()
        if not isinstance(module, dict):
            continue
        for resource in module.get("resources") or []:
            if isinstance(resource, dict) and isinstance(resource.get("address"), str):
                expressions = resource.get("expressions")
                index[prefix + resource["address"]] = expressions if isinstance(expressions, dict) else {}
        for name, call in (module.get("module_calls") or {}).items():
            if isinstance(call, dict):
                pending.append((f"{prefix}module.{name}.", call.get("module")))
    return index


def _config_address(address: str) -> str:
    """The configuration address of a resource instance: module.a.aws_x.y for module.a[0].aws_x.y["k"]."""
    return INSTANCE_KEY.sub("", address)


def _tables_with_unknown_routes(plan: dict[str, Any], config: dict[str, dict[str, Any]]) -> set[str]:
    """Route tables that a separate aws_route targets with a route that could reach the internet.

    That includes a destination or gateway known only after apply: see _default_route_via_gateway.
    """
    tables: set[str] = set()
    for change in plan.get("resource_changes", []):
        if not isinstance(change, dict) or change.get("type") != "aws_route" or change.get("mode") == "data":
            continue
        body = change.get("change") or {}
        after, unknown = body.get("after"), body.get("after_unknown")
        if not isinstance(after, dict) or not isinstance(unknown, dict):
            continue
        if not _default_route_via_gateway(after, unknown):
            continue
        address = _config_address(str(change.get("address")))
        prefix = "".join(f"{part}." for part in address.split(".")[:-2])
        table_id = config.get(address, {}).get("route_table_id")
        references = table_id.get("references") if isinstance(table_id, dict) else None
        for reference in references or []:
            parts = INSTANCE_KEY.sub("", reference).split(".") if isinstance(reference, str) else []
            if len(parts) >= 2 and parts[0] in ROUTE_TABLE_TYPES:
                tables.add(f"{prefix}{parts[0]}.{parts[1]}")
    return tables


def _routes_configured(address: str, config: dict[str, dict[str, Any]] | None, targeted: set[str]) -> bool:
    """True unless the configuration shows a route table with no route blocks and no risky aws_route targeting it."""
    if config is None or address not in config:
        return True
    expressions = config[address]
    if "route" in expressions and not _empty_constant(expressions["route"]):
        return True
    return address in targeted


def _empty_constant(expression: Any) -> bool:
    """An expression that is a literal null or empty collection, such as route = []."""
    return isinstance(expression, dict) and set(expression) == {"constant_value"} and not expression["constant_value"]


def _route_table_violations(address: str, routes: list[Any], routes_unknown: Any, configured: bool) -> list[str]:
    """Inline routes: a route known only after apply is refused, even next to known routes.

    A table without route blocks gets route = unknown in an initial plan, because the provider computes the
    attribute. That passes when no route is configured for the table (see _routes_configured).
    """
    if routes_unknown is True:
        if not routes and not configured:
            return []
        return [f"{address}: routes are unknown until apply"]
    unknown_list = routes_unknown if isinstance(routes_unknown, list) else []
    found: list[str] = []
    for i in range(max(len(routes), len(unknown_list))):
        route = routes[i] if i < len(routes) else None
        route_unknown = unknown_list[i] if i < len(unknown_list) else {}
        if route_unknown is True or (route is None and route_unknown):
            return [f"{address}: routes are unknown until apply"]
        if not isinstance(route, dict):
            continue
        if _default_route_via_gateway(route, route_unknown if isinstance(route_unknown, dict) else {}):
            found.append(f"{address}: default route to the internet")
    return found


def _allows_anyone(policy: Any) -> bool:
    """True when a policy document has an Allow statement for any principal ("*") that no Condition key limits."""
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
        # "*" under any principal type (AWS, Service, Federated, CanonicalUser) counts as anyone.
        anyone = principal == "*" or (
            isinstance(principal, dict) and any("*" in _as_list(value) for value in principal.values())
        )
        if statement.get("Effect") == "Allow" and anyone and not _limits_callers(statement.get("Condition")):
            return True
    return False


def _limits_callers(condition: Any) -> bool:
    """True when a Condition ties the statement to concrete, known callers.

    Negated, Null and IfExists operators let callers without the key through. A wildcard value ("*" or "?") matches
    anyone, and "anonymous" is the value aws:PrincipalAccount takes for unsigned requests. ForAllValues is true when
    the key is absent, so it counts only alongside a Null check that requires the key.
    """
    if not isinstance(condition, dict):
        return False
    required = _required_keys(condition)
    for operator, block in condition.items():
        if not isinstance(operator, str) or not isinstance(block, dict):
            continue
        if "Not" in operator or operator == "Null" or operator.endswith("IfExists"):
            continue
        for key, value in block.items():
            name = key.lower() if isinstance(key, str) else ""
            if name not in RESTRICTING_CONDITION_KEYS or not _concrete(value):
                continue
            if operator.startswith("ForAllValues:") and name not in required:
                continue
            return True
    return False


def _required_keys(condition: dict[str, Any]) -> set[str]:
    """Condition keys a Null operator requires to be present ("false" means the key must exist)."""
    block = condition.get("Null")
    if not isinstance(block, dict):
        return set()
    return {key.lower() for key, value in block.items() if isinstance(key, str) and _is_false(value)}


def _is_false(value: Any) -> bool:
    return all(v is False or (isinstance(v, str) and v.lower() == "false") for v in _as_list(value))


def _concrete(value: Any) -> bool:
    """A non-empty list of literal values: no wildcard pattern, no "anonymous" and no policy variable.

    A policy variable such as ${aws:PrincipalAccount} resolves to the caller's own value, so it matches every caller.
    """
    values = _as_list(value)
    return bool(values) and all(
        isinstance(v, str) and v and "*" not in v and "?" not in v and "${" not in v and v.lower() != "anonymous"
        for v in values
    )


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


def violations(plan: dict[str, Any]) -> list[str]:
    found: list[str] = []
    config = _config_expressions(plan)
    targeted = _tables_with_unknown_routes(plan, config) if config is not None else set()
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
            # A value known only after apply could be true, so it is refused like true.
            nets_unknown = unknown.get("network_configuration")
            for i, net in enumerate(after.get("network_configuration") or []):
                net_unknown = nets_unknown[i] if isinstance(nets_unknown, list) and i < len(nets_unknown) else {}
                maybe_public = isinstance(net_unknown, dict) and net_unknown.get("assign_public_ip")
                if net.get("assign_public_ip") or maybe_public:
                    found.append(f"{address}: ECS tasks must run with assign_public_ip = false")
            if nets_unknown is True:
                found.append(f"{address}: ECS network configuration is unknown until apply")
        elif rtype == "aws_subnet" and after.get("map_public_ip_on_launch"):
            found.append(f"{address}: subnet maps public IP addresses on launch")
        elif rtype == "aws_instance" and after.get("associate_public_ip_address"):
            found.append(f"{address}: instance gets a public IP address")
        elif rtype in PUBLICLY_ACCESSIBLE_TYPES and after.get("publicly_accessible"):
            found.append(f"{address}: publicly_accessible must be false")
        elif rtype == "aws_route" and _default_route_via_gateway(after, unknown):
            found.append(f"{address}: default route to the internet")
        elif rtype in ROUTE_TABLE_TYPES:
            configured = _routes_configured(_config_address(address), config, targeted)
            found.extend(_route_table_violations(address, after.get("route") or [], unknown.get("route"), configured))
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
