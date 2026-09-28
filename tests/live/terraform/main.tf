# The network every live test runs in: a dedicated VPC with private subnets
# only. No internet gateway, no NAT gateway, no route besides the VPC's local
# route and the S3 gateway endpoint. ECS tasks reach ECR, S3 and CloudWatch
# Logs through VPC endpoints. docs/adr/0012-live-tests-run-private-only.md.

locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : ["${var.aws_region}a", "${var.aws_region}b"]
  # Services the Fargate task's ENI calls: image manifest (ecr.api), image
  # layers (ecr.dkr, then S3 through the gateway endpoint) and awslogs (logs).
  interface_services = var.interface_endpoints ? toset(["ecr.api", "ecr.dkr", "logs"]) : toset([])
}

resource "aws_vpc" "live" {
  #checkov:skip=CKV2_AWS_11:Short-lived live-test VPC with no internet path; each run destroys it.
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-live" }
}

# Takes over the default security group and leaves it with no rules.
resource "aws_default_security_group" "live" {
  vpc_id  = aws_vpc.live.id
  ingress = []
  egress  = []
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.live.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr_block, 8, count.index)
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

# route = [] removes every route but the local one; the S3 gateway endpoint
# adds its prefix-list route through its own association.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.live.id
  route  = []

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.live.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-endpoints"
  description = "Interface endpoints of the ${var.name} live run"
  vpc_id      = aws_vpc.live.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from inside the VPC"
  cidr_ipv4         = aws_vpc.live.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = aws_vpc.live.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]

  tags = { Name = "${var.name}-${each.value}" }
}
