provider "aws" {
  region = "us-east-1"
}

variable "ssh_key_name" {
  description = "Name of the AWS EC2 SSH key pair to use. Must exist in your AWS account."
  type        = string
}

variable "agent_count" {
  description = "Number of k3s agent nodes to provision"
  type        = number
  default     = 2
}

variable "server_public_ip" {
  description = "Public IP of the k3s server node"
  type        = string
}

variable "k3s_server_token" {
  description = "k3s server node token for agent join"
  type        = string
}

resource "aws_instance" "k3s_agent" {
  count         = var.agent_count
  ami           = "ami-0bbdd8c17ed981ef9"
  instance_type = "t3.small"
  subnet_id     = "<subnet_id_from_server_module>" # Replace with output or data source
  vpc_security_group_ids = ["<sg_id_from_server_module>"] # Replace with output or data source
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/../../cluster/user_data.tpl", {
    NODE_INDEX = count.index + 1
    SERVER_IP   = var.server_public_ip
    K3S_TOKEN   = var.k3s_server_token
  })
  key_name = var.ssh_key_name
  tags = {
    Name = "k3s-agent-${count.index + 1}"
  }
}

output "agent_public_ips" {
  value = [for i in aws_instance.k3s_agent : i.public_ip]
}
