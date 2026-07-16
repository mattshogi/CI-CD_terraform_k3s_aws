# Minimal public network for a single-node demo cluster: one VPC, one public
# subnet with a default route through an internet gateway. No NAT gateway and
# no explicit NACL — the VPC default NACL already allows all traffic, and the
# security group is the enforcement point.

locals {
  name = var.name_suffix != "" ? "k3s-${var.environment}-${var.name_suffix}" : "k3s-${var.environment}"

  # Empty AZ list → one subnet in an AWS-chosen AZ (legacy behavior).
  # Non-empty → one subnet per AZ with non-colliding CIDRs (ha_mode).
  explicit_azs = length(var.availability_zones) > 0
  subnet_count = local.explicit_azs ? length(var.availability_zones) : 1
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

# Accepted risk: this is deliberately a public subnet — the demo node serves
# HTTP directly and there is no NAT gateway / load balancer in this topology
# (cost). Private subnets + NAT would be the first change for a real service.
#trivy:ignore:AVD-AWS-0164
resource "aws_subnet" "public" {
  count                   = local.subnet_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.explicit_azs ? cidrsubnet(var.vpc_cidr, 8, count.index + 1) : var.public_subnet_cidr
  availability_zone       = local.explicit_azs ? var.availability_zones[count.index] : null
  map_public_ip_on_launch = true

  tags = {
    Name = local.subnet_count > 1 ? "${local.name}-public-${count.index}" : "${local.name}-public"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-public-rt"
  }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = local.subnet_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#
# VPC flow logs → CloudWatch (short retention; this is an ephemeral demo VPC)
#

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc-flow-logs/${local.name}"
  retention_in_days = 7
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "publish-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = {
    Name = "${local.name}-flow-log"
  }
}
