variable "name" {
  description = "Base name for the load balancer and its target groups."
  type        = string
}

variable "vpc_id" {
  description = "VPC the target groups live in."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet ids the NLB spans (one per AZ)."
  type        = list(string)
}

variable "target_instance_ids" {
  description = "EC2 instance ids to register as targets on both the HTTP (80) and HTTPS (443) target groups."
  type        = list(string)
  default     = []
}
