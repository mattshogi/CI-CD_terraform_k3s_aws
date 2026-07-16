# Root composition: network (created or reused), SSM access, Grafana secret,
# and the k3s server node. Modules hold the reusable building blocks; this
# file wires them together for a single-node demo cluster.

locals {
  name_suffix = var.resource_name_suffix != "" ? "-${var.resource_name_suffix}" : ""
  name        = "k3s-${var.environment}${local.name_suffix}"

  vpc_id = var.vpc_id != "" ? var.vpc_id : module.network[0].vpc_id

  # AZ selection from the AZs that actually offer the requested instance type.
  # HA needs 3 (odd-sized etcd quorum); single-node pins to the first.
  offered_azs = sort(data.aws_ec2_instance_type_offerings.requested.locations)
  azs         = var.ha_mode ? slice(local.offered_azs, 0, 3) : [local.offered_azs[0]]

  server_count = var.ha_mode ? 3 : 1

  # Subnet ids: reuse an existing VPC's public subnets, or the ones the network
  # module just created (one per AZ). subnet_id keeps the first for callers that
  # only need a single subnet (single-node compatibility).
  subnet_ids = var.vpc_id != "" ? data.aws_subnets.existing_public[0].ids : module.network[0].public_subnet_ids
  subnet_id  = local.subnet_ids[0]

  # Installer and chart source pinned to a specific git ref; the checksum is
  # computed from the working tree at plan time and verified on the instance.
  install_script_url    = "https://raw.githubusercontent.com/${var.github_repository}/${var.repo_ref}/cluster/k3s_install.sh"
  install_script_sha256 = filesha256("${path.module}/../cluster/k3s_install.sh")
  repo_tarball_url      = "https://github.com/${var.github_repository}/archive/${var.repo_ref}.tar.gz"

  grafana_admin_password = var.enable_monitoring ? (
    var.grafana_admin_password != "" ? var.grafana_admin_password : random_password.grafana_admin[0].result
  ) : ""

  # NodePorts an operator may need to reach directly (app, Grafana, Prometheus)
  admin_node_ports = concat(
    [var.hello_node_port],
    var.enable_monitoring ? [30030, 30900] : []
  )

  # Join token: only meaningful in HA (peers authenticate to the primary with
  # it). Empty in single-node mode, which keeps user_data byte-for-byte as before.
  k3s_token = var.ha_mode ? random_password.k3s_token[0].result : ""

  # Keys shared by every node's user_data. Per-node keys (NODE_INDEX,
  # CLUSTER_INIT, SERVER_JOIN_URL, TLS_HOST) are merged in at each module call.
  # The four HA_* keys are unused by the current single-node template; extra
  # templatefile vars are ignored, so this stays compatible until the bootstrap
  # teammate's template consumes them.
  user_data_common = {
    SERVER_IP              = ""
    K3S_TOKEN              = local.k3s_token
    HA_MODE                = var.ha_mode ? "true" : "false"
    ENABLE_MONITORING      = var.enable_monitoring ? "true" : "false"
    ENABLE_INGRESS_NGINX   = var.enable_ingress_nginx ? "true" : "false"
    ENABLE_TLS             = var.enable_tls ? "true" : "false"
    ENABLE_GITOPS          = var.enable_gitops ? "true" : "false"
    GITOPS_REPO_URL        = "https://github.com/${var.github_repository}"
    GITOPS_REF             = var.repo_ref
    APP_IMAGE              = var.app_image
    HELLO_NODE_PORT        = tostring(var.hello_node_port)
    INSTALL_SCRIPT_URL     = local.install_script_url
    INSTALL_SCRIPT_SHA256  = local.install_script_sha256
    REPO_TARBALL_URL       = local.repo_tarball_url
    INSTALL_DOCKER         = var.install_docker ? "true" : "false"
    GRAFANA_ADMIN_PASSWORD = local.grafana_admin_password
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Packer-baked node image (see packer/ and the bake-ami workflow)
data "aws_ami" "baked" {
  count       = var.use_baked_ami ? 1 : 0
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = ["k3s-node-*"]
  }
}

#
# Network: create a VPC unless reusing an existing one
#

# Not every AZ offers every instance type (us-east-1e has no t3.medium);
# pin the subnet to an AZ that actually carries the requested type.
data "aws_ec2_instance_type_offerings" "requested" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  lifecycle {
    postcondition {
      condition     = length(self.locations) > 0
      error_message = "Instance type ${var.instance_type} is not offered in any AZ of this region."
    }

    # HA spreads 3 servers across 3 AZs for an odd-sized etcd quorum.
    postcondition {
      condition     = !var.ha_mode || length(self.locations) >= 3
      error_message = "ha_mode requires at least 3 AZs offering ${var.instance_type} in ${var.aws_region}; only ${length(self.locations)} offer it. Choose a more widely available instance type or disable ha_mode."
    }
  }
}

module "network" {
  count  = var.vpc_id == "" ? 1 : 0
  source = "./modules/network"

  environment        = var.environment
  name_suffix        = var.resource_name_suffix
  availability_zones = local.azs
}

# When reusing an existing VPC, find its public subnets (any subnet that maps
# public IPs on launch) and use the first. aws_subnets tolerates multiple
# matches, unlike the singular aws_subnet data source.
data "aws_subnets" "existing_public" {
  count = var.vpc_id != "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "VPC ${var.vpc_id} has no subnets with map-public-ip-on-launch=true."
    }
  }
}

#
# SSM access (Session Manager) — the intended alternative to SSH
#

resource "aws_iam_role" "k3s_ssm_role" {
  count = var.enable_ssm ? 1 : 0
  name  = "${local.name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "k3s_ssm_core" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.k3s_ssm_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s_ssm_profile" {
  count = var.enable_ssm ? 1 : 0
  name  = "${local.name}-ssm-profile"
  role  = aws_iam_role.k3s_ssm_role[0].name
}

# IAM is eventually consistent: give the instance profile time to propagate
# before RunInstances references it (mitigates InvalidIAMInstanceProfile).
resource "time_sleep" "iam_propagation_delay" {
  count           = var.enable_ssm ? 1 : 0
  create_duration = "45s"
  depends_on      = [aws_iam_instance_profile.k3s_ssm_profile]
}

#
# Grafana admin credential: generated unless provided, stored in SSM
#

resource "random_password" "grafana_admin" {
  count   = var.enable_monitoring && var.grafana_admin_password == "" ? 1 : 0
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  count = var.enable_monitoring ? 1 : 0
  name  = "/${local.name}/grafana-admin-password"
  type  = "SecureString"
  value = local.grafana_admin_password
}

#
# k3s cluster join token (HA only): shared secret peers use to join the primary
#

resource "random_password" "k3s_token" {
  count   = var.ha_mode ? 1 : 0
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "k3s_join_token" {
  count = var.ha_mode ? 1 : 0
  name  = "/${local.name}/k3s-join-token"
  type  = "SecureString"
  value = random_password.k3s_token[0].result
}

#
# k3s server node(s)
#
# The primary (node 0) is a standalone module instance; the HA peers are a
# separate counted instance. This split is what lets the peers reference the
# primary's private IP (SERVER_JOIN_URL) — a single counted module cannot refer
# to module.self[0] from within its own count. It also gives natural ordering:
# the primary is created first, then peers join it.
#
# Precedence for the AMI: explicit override > baked AMI > stock Ubuntu.
locals {
  node_ami_id = var.ami_id != "" ? var.ami_id : (var.use_baked_ami ? data.aws_ami.baked[0].id : data.aws_ami.ubuntu.id)
}

# Public NLB fronting web traffic across all servers (HA only). Created before
# the nodes: aws_lb.dns_name is known without the instances, so it can be fed
# into node user_data (TLS_HOST). Instances are attached afterwards — see the
# ordering note in modules/nlb.
module "nlb" {
  count  = var.ha_mode ? 1 : 0
  source = "./modules/nlb"

  name                = local.name
  vpc_id              = local.vpc_id
  subnet_ids          = local.subnet_ids
  target_instance_ids = concat([module.k3s_server.instance_id], module.k3s_joiners[*].instance_id)
}

# Primary server (node 0). Bootstraps the cluster (CLUSTER_INIT) in HA mode.
module "k3s_server" {
  source = "./modules/k3s-node"

  name          = var.ha_mode ? "${local.name}-0" : local.name
  vpc_id        = local.vpc_id
  subnet_id     = element(local.subnet_ids, 0)
  ami_id        = local.node_ami_id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name
  cluster_mode  = var.ha_mode

  iam_instance_profile = var.enable_ssm ? aws_iam_instance_profile.k3s_ssm_profile[0].name : ""
  user_data = templatefile("${path.module}/../cluster/user_data.tpl", merge(local.user_data_common, {
    NODE_INDEX      = 0
    CLUSTER_INIT    = var.ha_mode ? "true" : "false"
    SERVER_JOIN_URL = ""
    TLS_HOST        = var.ha_mode ? module.nlb[0].dns_name : ""
  }))

  public_ports = var.enable_tls ? [80, 443] : [80]
  admin_cidr   = var.admin_cidr
  admin_ports  = concat([6443], local.admin_node_ports)

  depends_on = [time_sleep.iam_propagation_delay]
}

# HA peers (nodes 1 and 2). Join the primary over its private IP; never do
# CLUSTER_INIT. Only exist in HA mode.
module "k3s_joiners" {
  count  = var.ha_mode ? 2 : 0
  source = "./modules/k3s-node"

  name          = "${local.name}-${count.index + 1}"
  vpc_id        = local.vpc_id
  subnet_id     = element(local.subnet_ids, count.index + 1)
  ami_id        = local.node_ami_id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name
  cluster_mode  = var.ha_mode

  iam_instance_profile = var.enable_ssm ? aws_iam_instance_profile.k3s_ssm_profile[0].name : ""
  user_data = templatefile("${path.module}/../cluster/user_data.tpl", merge(local.user_data_common, {
    NODE_INDEX      = count.index + 1
    CLUSTER_INIT    = "false"
    SERVER_JOIN_URL = "https://${module.k3s_server.private_ip}:6443"
    TLS_HOST        = module.nlb[0].dns_name
  }))

  public_ports = var.enable_tls ? [80, 443] : [80]
  admin_cidr   = var.admin_cidr
  admin_ports  = concat([6443], local.admin_node_ports)

  depends_on = [time_sleep.iam_propagation_delay]
}
