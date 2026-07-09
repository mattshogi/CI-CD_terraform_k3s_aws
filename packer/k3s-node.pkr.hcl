# Bakes a k3s-ready AMI: base Ubuntu 22.04 with system deps, Helm, the k3s
# binary, and the k3s airgap image bundle pre-loaded. Cuts instance boot →
# cluster-ready time by removing the largest boot-time downloads.
#
# The k3s *service* is intentionally not enabled at bake time — node identity
# and runtime flags (traefik on/off, etc.) are per-instance concerns; the
# bootstrap installer detects the baked binary and skips the download
# (INSTALL_K3S_SKIP_DOWNLOAD) while still generating the service unit.
#
# Build (CI): .github/workflows/bake-ami.yml
# Build (local): packer init packer/ && packer build packer/
# Uses the account's default VPC for the temporary build instance.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

data "amazon-ami" "ubuntu" {
  region      = var.aws_region
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

source "amazon-ebs" "k3s_node" {
  region        = var.aws_region
  instance_type = var.instance_type
  source_ami    = data.amazon-ami.ubuntu.id
  ssh_username  = "ubuntu"

  ami_name        = "k3s-node-${local.timestamp}"
  ami_description = "Ubuntu 22.04 + k3s binary/images + helm, baked by Packer"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name      = "k3s-node-${local.timestamp}"
    Project   = "CI-CD_terraform_k3s_aws"
    ManagedBy = "packer"
    BaseAMI   = "{{ .SourceAMI }}"
  }
}

build {
  sources = ["source.amazon-ebs.k3s_node"]

  provisioner "shell" {
    # bash, not sh: the airgap URL uses ${VAR/+/%2B} substitution
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -euo pipefail",

      "echo '[BAKE] System packages'",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq zstd",

      "echo '[BAKE] Helm'",
      "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash",

      "echo '[BAKE] k3s binary (service not enabled; per-instance flags applied at boot)'",
      "curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_START=true sudo -E sh -",

      "echo '[BAKE] k3s airgap images (traefik/coredns/pause pre-loaded)'",
      "K3S_VER=$(k3s --version | head -1 | awk '{print $3}')",
      "sudo mkdir -p /var/lib/rancher/k3s/agent/images",
      "sudo curl -fL -o /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst \"https://github.com/k3s-io/k3s/releases/download/$${K3S_VER/+/%2B}/k3s-airgap-images-amd64.tar.zst\"",

      "echo '[BAKE] Reset cloud-init so user_data runs fresh on instances from this AMI'",
      "sudo cloud-init clean --logs",

      "echo '[BAKE] Done'",
    ]
  }
}
