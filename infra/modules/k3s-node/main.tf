# A single k3s node: hardened EC2 instance plus its security group.
#
# Security posture:
#   - Only the demo HTTP port(s) are public.
#   - SSH (22), the Kubernetes API (6443) and NodePorts are restricted to
#     admin_cidr, and closed entirely when admin_cidr is empty. Day-to-day
#     access is AWS SSM Session Manager, which needs no inbound rules.
#   - IMDSv2 enforced; hop limit 1 keeps pods on the overlay network from
#     reaching the instance credentials.
#   - Encrypted gp3 root volume.

locals {
  public_rules = {
    for port in var.public_ports :
    "public-${port}" => { port = port, cidrs = ["0.0.0.0/0"], desc = "public demo endpoint" }
  }

  admin_rules = var.admin_cidr == "" ? {} : {
    for port in var.admin_ports :
    "admin-${port}" => { port = port, cidrs = [var.admin_cidr], desc = "operator access" }
  }

  ssh_rules = (var.admin_cidr != "" && var.key_name != "") ? {
    "ssh-22" = { port = 22, cidrs = [var.admin_cidr], desc = "operator SSH" }
  } : {}

  ingress_rules = merge(local.public_rules, local.admin_rules, local.ssh_rules)

  # Intra-cluster ports for a multi-server k3s with embedded etcd. Sourced from
  # the node SG itself (self = true) so only peer nodes can reach them. Empty
  # in single-node mode, which keeps the SG byte-for-byte as before.
  cluster_rules = var.cluster_mode ? {
    "cluster-api-6443" = { from = 6443, to = 6443, protocol = "tcp", desc = "k3s API server (intra-cluster join)" }
    "cluster-etcd"     = { from = 2379, to = 2380, protocol = "tcp", desc = "embedded etcd client/peer" }
    "cluster-flannel"  = { from = 8472, to = 8472, protocol = "udp", desc = "flannel VXLAN overlay" }
    "cluster-kubelet"  = { from = 10250, to = 10250, protocol = "tcp", desc = "kubelet metrics/exec" }
  } : {}
}

resource "aws_security_group" "node" {
  name        = "${var.name}-sg"
  description = "k3s node: public HTTP plus admin-restricted SSH/API/NodePorts"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.ingress_rules
    content {
      description = ingress.value.desc
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidrs
    }
  }

  # Self-referencing intra-cluster rules (only present when cluster_mode = true).
  dynamic "ingress" {
    for_each = local.cluster_rules
    content {
      description = ingress.value.desc
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.protocol
      self        = true
    }
  }

  # Accepted risk: the node bootstraps from the public internet (get.k3s.io,
  # apt, GHCR, Helm repos) and has no NAT/proxy in this single-node topology,
  # so egress stays open. Revisit if a VPC endpoint/proxy architecture lands.
  #trivy:ignore:AVD-AWS-0104
  egress {
    description = "all egress (image pulls, package installs, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

resource "aws_instance" "node" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.node.id]
  associate_public_ip_address = true
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = var.iam_instance_profile != "" ? var.iam_instance_profile : null
  user_data                   = var.user_data

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  tags = merge(
    { Name = var.name },
    var.extra_tags,
  )
}
