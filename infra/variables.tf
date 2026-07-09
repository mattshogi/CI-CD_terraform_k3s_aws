variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, production, or an ephemeral CI label)."
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type for the k3s server. t3.micro suffices for the bare cluster + app; use t3.small (or larger) with monitoring enabled."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Optional override for the EC2 AMI id. Leave blank to auto-select the latest Ubuntu 22.04 LTS (amd64, hvm, ebs)."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "Optional: reuse an existing VPC by id (avoids per-account VPC limits). If empty, a new VPC is created."
  type        = string
  default     = ""
}

variable "ssh_key_name" {
  description = "Optional name of an existing EC2 key pair. Leave blank to launch without SSH access — SSM Session Manager is the intended access path."
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "CIDR allowed to reach operator-only ports (SSH, Kubernetes API 6443, NodePorts). Empty (default) closes them entirely; SSM Session Manager still works. CI sets this to the runner's IP for endpoint validation."
  type        = string
  default     = ""
}

variable "enable_ssm" {
  description = "Attach an IAM role with AmazonSSMManagedInstanceCore so the instance is reachable via SSM Session Manager (recommended; replaces SSH)."
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Install the kube-prometheus-stack (Prometheus + Grafana)."
  type        = bool
  default     = false
}

variable "enable_ingress_nginx" {
  description = "Install nginx ingress controller instead of k3s's bundled traefik."
  type        = bool
  default     = false
}

variable "app_image" {
  description = "Container image (repository:tag) for the hello-world deployment. Defaults to the artifact built by this repo's CI; the bootstrap falls back to hashicorp/http-echo if the image cannot be pulled."
  type        = string
  default     = "ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world:latest"
}

variable "hello_node_port" {
  description = "NodePort for the hello-world service (reachable from admin_cidr only)."
  type        = number
  default     = 30080
}

variable "grafana_admin_password" {
  description = "Grafana admin password when monitoring is enabled. Leave empty to generate a random one; either way it is stored in SSM Parameter Store (SecureString)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "install_docker" {
  description = "Install the Docker engine on the node. Not needed to run k3s workloads (containerd is the runtime); only enable for docker-based debugging."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub owner/repo this deployment fetches its installer and Helm chart from."
  type        = string
  default     = "mattshogi/CI-CD_terraform_k3s_aws"
}

variable "repo_ref" {
  description = "Git ref (commit SHA, tag, or branch) the instance fetches the installer and chart at. CI passes the exact commit SHA being deployed so boot-time behavior is pinned to the planned revision instead of floating on main."
  type        = string
  default     = "main"
}

variable "resource_name_suffix" {
  description = "Optional suffix appended to resource names (e.g. CI run id) so concurrent ephemeral environments don't collide on named resources (IAM role, SG)."
  type        = string
  default     = ""
}
