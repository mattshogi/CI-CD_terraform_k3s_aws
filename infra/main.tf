# Root composition: network (created or reused), SSM access, Grafana secret,
# and the k3s server node. Modules hold the reusable building blocks; this
# file wires them together for a single-node demo cluster.

locals {
  name_suffix = var.resource_name_suffix != "" ? "-${var.resource_name_suffix}" : ""
  name        = "k3s-${var.environment}${local.name_suffix}"

  vpc_id    = var.vpc_id != "" ? var.vpc_id : module.network[0].vpc_id
  subnet_id = var.vpc_id != "" ? data.aws_subnets.existing_public[0].ids[0] : module.network[0].public_subnet_id

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

  user_data = templatefile("${path.module}/../cluster/user_data.tpl", {
    NODE_INDEX             = 0
    SERVER_IP              = ""
    K3S_TOKEN              = ""
    ENABLE_MONITORING      = var.enable_monitoring ? "true" : "false"
    ENABLE_INGRESS_NGINX   = var.enable_ingress_nginx ? "true" : "false"
    ENABLE_TLS             = var.enable_tls ? "true" : "false"
    APP_IMAGE              = var.app_image
    HELLO_NODE_PORT        = tostring(var.hello_node_port)
    INSTALL_SCRIPT_URL     = local.install_script_url
    INSTALL_SCRIPT_SHA256  = local.install_script_sha256
    REPO_TARBALL_URL       = local.repo_tarball_url
    INSTALL_DOCKER         = var.install_docker ? "true" : "false"
    GRAFANA_ADMIN_PASSWORD = local.grafana_admin_password
  })
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

module "network" {
  count  = var.vpc_id == "" ? 1 : 0
  source = "./modules/network"

  environment = var.environment
  name_suffix = var.resource_name_suffix
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
# k3s server node
#

module "k3s_server" {
  source = "./modules/k3s-node"

  name      = local.name
  vpc_id    = local.vpc_id
  subnet_id = local.subnet_id
  # Precedence: explicit override > baked AMI > stock Ubuntu
  ami_id        = var.ami_id != "" ? var.ami_id : (var.use_baked_ami ? data.aws_ami.baked[0].id : data.aws_ami.ubuntu.id)
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  iam_instance_profile = var.enable_ssm ? aws_iam_instance_profile.k3s_ssm_profile[0].name : ""
  user_data            = local.user_data

  public_ports = var.enable_tls ? [80, 443] : [80]
  admin_cidr   = var.admin_cidr
  admin_ports  = concat([6443], local.admin_node_ports)

  depends_on = [time_sleep.iam_propagation_delay]
}
