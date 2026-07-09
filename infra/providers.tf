provider "aws" {
  region = var.aws_region

  # Applied to every resource; per-resource tags only add Name/specifics.
  default_tags {
    tags = {
      Project     = "CI-CD_terraform_k3s_aws"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
