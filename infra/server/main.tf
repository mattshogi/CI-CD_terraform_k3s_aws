provider "aws" {
  region = "us-east-1"
}

variable "ssh_key_name" {
  description = "Name of the AWS EC2 SSH key pair to use. Must exist in your AWS account."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, production)"
  type        = string
  default     = "dev"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name        = "k3s-vpc-${var.environment}"
    Environment = var.environment
    Project     = "k3s-demo"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name        = "k3s-public-subnet-${var.environment}"
    Environment = var.environment
    Project     = "k3s-demo"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2_sg" {
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  name        = "ec2_sg"
  description = "Allow SSH, HTTP, k3s, nginx Ingress"
  vpc_id      = aws_vpc.main.id

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
    Name        = "k3s-sg-${var.environment}"
    Environment = var.environment
    Project     = "k3s-demo"
  }
}

resource "aws_network_acl" "public" {
  vpc_id = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id]

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

resource "aws_instance" "k3s_server2" {
  ami           = "ami-021589336d307b577" # Official Ubuntu 22.04 LTS AMI (2025-08-01)
  instance_type = "t3.small"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  # Use the same templated user_data approach as the primary module
  user_data = templatefile("${path.module}/../../cluster/user_data.tpl", {
    NODE_INDEX       = 0
    SERVER_IP        = ""
    K3S_TOKEN        = ""
    installer_script = file("${path.module}/../../cluster/k3s_install.sh")
  })
  key_name = var.ssh_key_name
  tags = {
  Name        = "k3s-server-${var.environment}"
  Environment = var.environment
  Project     = "k3s-demo"
  }
}

output "server_public_ip" {
  value = aws_instance.k3s_server2.public_ip
}
