variable "name" {
  description = "Base name for the instance and its security group."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the node's security group in."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the instance into."
  type        = string
}

variable "ami_id" {
  description = "AMI id for the instance."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "key_name" {
  description = "Optional EC2 key pair name. Empty disables SSH entirely (SSM is the intended access path)."
  type        = string
  default     = ""
}

variable "iam_instance_profile" {
  description = "Optional IAM instance profile name (e.g. for SSM access)."
  type        = string
  default     = ""
}

variable "user_data" {
  description = "Rendered user_data script for instance bootstrap."
  type        = string
}

variable "public_ports" {
  description = "TCP ports open to the world (the demo's public HTTP endpoint)."
  type        = list(number)
  default     = [80]
}

variable "admin_cidr" {
  description = "CIDR allowed to reach operator-only ports (SSH, Kubernetes API, NodePorts). Empty closes those ports entirely — SSM Session Manager still works without any inbound rule."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_cidr == "" || can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be empty or a valid CIDR block (e.g. 203.0.113.7/32)."
  }
}

variable "admin_ports" {
  description = "TCP ports opened only to admin_cidr (Kubernetes API, NodePorts for app/Grafana/Prometheus)."
  type        = list(number)
  default     = [6443]
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 16
}

variable "extra_tags" {
  description = "Additional tags for the instance."
  type        = map(string)
  default     = {}
}
