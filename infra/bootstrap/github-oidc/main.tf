# One-time bootstrap: federate GitHub Actions with AWS via OIDC so workflows
# assume a short-lived role instead of storing long-lived access keys as
# repository secrets.
#
#   terraform init && terraform apply
#   → set the `role_arn` output as repository variable AWS_ROLE_ARN
#
# Applied with human credentials once; not part of the ephemeral stack.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub owner/repo allowed to assume the deploy role."
  type        = string
  default     = "mattshogi/CI-CD_terraform_k3s_aws"
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform remote state (from scripts/bootstrap_remote_state.sh)."
  type        = string
}

data "aws_caller_identity" "current" {}

# GitHub's OIDC identity provider. The thumbprint is not validated by AWS for
# GitHub's provider anymore (AWS pins GitHub's root CA), but the argument is
# still required by the API.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy: only workflows from this repository can assume the role.
# `sub` can be tightened further (e.g. repo:...:ref:refs/heads/main) to
# restrict deploys to specific branches or environments.
resource "aws_iam_role" "github_deploy" {
  name = "github-actions-deploy-k3s"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })
}

# Permissions scoped to what the ephemeral stack actually manages: EC2/VPC,
# the k3s-* IAM role/profile pair, k3s SSM parameters + SSM diagnostics, and
# the remote-state bucket.
resource "aws_iam_role_policy" "deploy_permissions" {
  name = "deploy-ephemeral-k3s"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Ec2AndNetworking"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid    = "ScopedIamForInstanceRole"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile", "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/k3s-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/k3s-*",
        ]
      },
      {
        Sid      = "PassInstanceRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/k3s-*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid    = "SsmParametersAndDiagnostics"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter", "ssm:GetParameter", "ssm:DeleteParameter",
          "ssm:DescribeParameters", # provider reads metadata after create
          "ssm:ListTagsForResource", "ssm:AddTagsToResource",
          "ssm:SendCommand", "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
      {
        Sid    = "RemoteState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.state_bucket}",
          "arn:aws:s3:::${var.state_bucket}/*",
        ]
      },
      {
        Sid      = "CallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}

output "role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository variable."
  value       = aws_iam_role.github_deploy.arn
}
