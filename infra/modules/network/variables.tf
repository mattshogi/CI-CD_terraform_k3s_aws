variable "environment" {
  description = "Environment name used in resource names."
  type        = string
}

variable "name_suffix" {
  description = "Optional suffix appended to resource names (e.g. CI run id) to avoid collisions between concurrent ephemeral environments."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zones" {
  description = "AZs to place public subnets in. Empty (default) creates a single subnet in an AWS-chosen AZ (legacy single-node behavior). A non-empty list creates one public subnet per AZ, each with a non-colliding CIDR carved with cidrsubnet(vpc_cidr, 8, index+1) — used by ha_mode to spread 3 server nodes across 3 AZs. Pin AZs to ones that actually offer your instance type (not all AZs carry all types; us-east-1e lacks t3.medium, for example)."
  type        = list(string)
  default     = []
}
