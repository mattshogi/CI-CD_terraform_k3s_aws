provider "aws" {
  region = "us-east-1"
}

variable "ssh_key_name" {
  description = "Name of the AWS EC2 SSH key pair to use. Must exist in your AWS account."
  type        = string
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

variable "k3s_server_token" {
  description = "k3s server node token for agent join (set after step 1)"
  type        = string
  default     = ""
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
  name        = "ec2_sg"
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
  ami                         = "ami-0bbdd8c17ed981ef9"
  instance_type               = var.instance_type
  subnet_id                   = var.vpc_id != "" ? data.aws_subnet.existing[0].id : aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/../cluster/user_data.tpl", {
    NODE_INDEX       = 0
    SERVER_IP        = ""
    K3S_TOKEN        = ""
    installer_script = file("${path.module}/../cluster/k3s_install.sh")
  })
  key_name = var.ssh_key_name
  tags = {
    Name = "k3s-server"
  }
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


