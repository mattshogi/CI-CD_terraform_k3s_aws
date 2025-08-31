# Copy this file to terraform.tfvars and update with your values

# Required: AWS EC2 Key Pair name (must exist in your AWS account)
ssh_key_name = "id_k3s_aws"

# Optional: Instance type (t3.micro for free tier, t3.small recommended)
instance_type = "t3.micro"

# Optional: Reuse existing VPC to avoid VPC limits
vpc_id = "vpc-0320fffd66ed1f568"

# Optional: Number of k3s agent nodes (0 for single-node cluster)
k3s_node_count = 0
