provider "aws" {
  region = "us-east-1"
}

variable "ssh_key_name" {
  description = "(Optional) Name of an existing AWS EC2 SSH key pair. Leave blank to create the instance without SSH access (used for ephemeral CI tests)."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for k3s nodes. Set to a free-tier compatible type (e.g. t3.micro) to avoid charges where possible."
  type        = string
  default     = "t3.micro"
}

variable "k3s_node_count" {
  description = "Number of k3s agent nodes to provision (set to 0 for step 1)"
  type        = number
  default     = 0
}

variable "environment" {
  description = "Environment name (staging, production, etc.)"
  type        = string
  default     = "dev"
}

variable "ami_id" {
  description = "Optional override for the EC2 AMI ID. Leave blank to auto-select the latest Ubuntu 22.04 LTS (amd64, hvm, ebs)."
  type        = string
  default     = ""
}

variable "k3s_server_token" {
  description = "k3s server node token for agent join (set after step 1)"
  type        = string
  default     = ""
}

variable "enable_monitoring" {
  description = "Install Prometheus + Grafana stack (kube-prometheus-stack)"
  type        = bool
  default     = false
}

variable "enable_ingress_nginx" {
  description = "Install nginx ingress controller instead of bundled traefik"
  type        = bool
  default     = false
}

variable "app_image" {
  description = "Container image (repository:tag) for Hello World deployment"
  type        = string
  default     = "hashicorp/http-echo:0.2.3"
}

variable "hello_node_port" {
  description = "NodePort to expose Hello World service"
  type        = number
  default     = 30080
}

variable "install_docker" {
  description = "Install Docker engine (not required for running k3s workloads; disable in low-memory ephemeral tests)"
  type        = bool
  default     = true
}

variable "enable_ssm" {
  description = "Attach an IAM role with SSM Core permissions so the instance can be accessed via AWS Systems Manager Session Manager (recommended when no SSH key is provided)."
  type        = bool
  default     = true
}

variable "install_script_url" {
  description = "URL to fetch k3s_install.sh (keeps user_data small to avoid 16KB limit)."
  type        = string
  default     = "https://raw.githubusercontent.com/mattshogi/CI-CD_terraform_k3s_aws/main/cluster/k3s_install.sh"
}

variable "resource_name_suffix" {
  description = "Optional suffix appended to resource names (e.g., CI run id) to avoid name collisions."
  type        = string
  default     = ""
}

locals {
  sg_base          = var.vpc_id != "" ? "ec2_sg-${substr(var.vpc_id, -4, 4)}" : "ec2_sg"
  sg_name          = var.resource_name_suffix != "" ? "${local.sg_base}-${var.resource_name_suffix}" : local.sg_base
  iam_role_name    = var.resource_name_suffix != "" ? "k3s-ssm-role-${var.environment}-${var.resource_name_suffix}" : "k3s-ssm-role-${var.environment}"
  iam_profile_name = var.resource_name_suffix != "" ? "k3s-ssm-profile-${var.environment}-${var.resource_name_suffix}" : "k3s-ssm-profile-${var.environment}"
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

variable "vpc_id" {
  description = "Optional: reuse an existing VPC by id. If empty, a new VPC will be created."
  type        = string
  default     = ""
}

resource "aws_vpc" "main" {
  count                = var.vpc_id == "" ? 1 : 0
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  count                   = var.vpc_id == "" ? 1 : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  count  = var.vpc_id == "" ? 1 : 0
  vpc_id = aws_vpc.main[0].id
}

resource "aws_route_table" "public" {
  count  = var.vpc_id == "" ? 1 : 0
  vpc_id = aws_vpc.main[0].id
}

resource "aws_route" "default" {
  count                  = var.vpc_id == "" ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw[0].id
}

resource "aws_route_table_association" "public" {
  count          = var.vpc_id == "" ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_security_group" "ec2_sg" {
  name        = local.sg_name
  description = "Allow SSH, HTTP, k3s, nginx Ingress"
  vpc_id      = var.vpc_id != "" ? var.vpc_id : aws_vpc.main[0].id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name         = local.sg_name
    Environment  = var.environment
    NodeCount    = tostring(var.k3s_node_count)
    TokenDefined = var.k3s_server_token != "" ? "true" : "false"
    Suffix       = var.resource_name_suffix
  }
}

resource "aws_network_acl" "public" {
  count      = var.vpc_id == "" ? 1 : 0
  vpc_id     = aws_vpc.main[0].id
  subnet_ids = [aws_subnet.public[0].id]

  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

resource "aws_instance" "k3s_server" {
  ami                         = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.vpc_id != "" ? data.aws_subnet.existing[0].id : aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = var.enable_ssm ? aws_iam_instance_profile.k3s_ssm_profile[0].name : null
  user_data = templatefile("${path.module}/../cluster/user_data.tpl", {
    NODE_INDEX           = 0
    SERVER_IP            = ""
    K3S_TOKEN            = ""
    ENABLE_MONITORING    = var.enable_monitoring ? "true" : "false"
    ENABLE_INGRESS_NGINX = var.enable_ingress_nginx ? "true" : "false"
    APP_IMAGE            = var.app_image
    HELLO_NODE_PORT      = tostring(var.hello_node_port)
    INSTALL_SCRIPT_URL   = var.install_script_url
    INSTALL_DOCKER       = var.install_docker ? "true" : "false"
  })
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null
  tags = {
    Name         = "k3s-server"
    Environment  = var.environment
    NodeCount    = tostring(var.k3s_node_count)
    TokenDefined = var.k3s_server_token != "" ? "true" : "false"
  }
}

#
# Optional: SSM access (Session Manager) so you can connect without SSH keys
#
resource "aws_iam_role" "k3s_ssm_role" {
  count = var.enable_ssm ? 1 : 0
  name  = local.iam_role_name
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
  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "k3s_ssm_core" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.k3s_ssm_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s_ssm_profile" {
  count = var.enable_ssm ? 1 : 0
  name  = local.iam_profile_name
  role  = aws_iam_role.k3s_ssm_role[0].name
}

// If reusing an existing VPC, lookup its subnets (pick the first) so we can place the instance
// When reusing an existing VPC, lookup the first public subnet by filtering for a subnet that
// maps public IPs on launch. Adjust the filter if your VPC uses different subnet tagging.
data "aws_subnet" "existing" {
  count = var.vpc_id != "" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}


