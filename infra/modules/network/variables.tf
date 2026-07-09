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
