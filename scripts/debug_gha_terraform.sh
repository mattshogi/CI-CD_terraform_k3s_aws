#!/bin/bash
# Debug script to replicate GitHub Actions Terraform environment locally
set -euo pipefail

echo "=== GitHub Actions Terraform Debug Script ==="
echo "This script replicates the GitHub Actions environment for debugging"
echo

# Check if we're in the right directory
if [ ! -f "infra/main.tf" ]; then
    echo "ERROR: Run this script from the repository root" >&2
    exit 1
fi

cd infra

echo "=== Environment Setup ==="
export TF_IN_AUTOMATION=1
export AWS_REGION=us-east-1
export TERRAFORM_CLI_ARGS=-no-color
echo "TF_IN_AUTOMATION=$TF_IN_AUTOMATION"
echo "AWS_REGION=$AWS_REGION"
echo "TERRAFORM_CLI_ARGS=$TERRAFORM_CLI_ARGS"
echo

echo "=== AWS Connectivity Test ==="
aws sts get-caller-identity
echo

echo "=== VPC and Subnet Check ==="
echo "Default VPCs:"
aws ec2 describe-vpcs --region $AWS_REGION --query 'Vpcs[?IsDefault==`true`].[VpcId,CidrBlock,State]' --output table || true
echo
echo "Default subnets:"
aws ec2 describe-subnets --region $AWS_REGION --query 'Subnets[?DefaultForAz==`true`].[SubnetId,VpcId,AvailabilityZone,CidrBlock]' --output table || true
echo

echo "=== IAM Permission Test ==="
echo "Testing EC2 permissions:"
aws ec2 describe-security-groups --region $AWS_REGION --max-items 1 >/dev/null && echo "✓ EC2 describe-security-groups OK" || echo "✗ EC2 describe-security-groups FAILED"
echo "Testing IAM permissions:"
aws iam list-roles --max-items 1 >/dev/null && echo "✓ IAM list-roles OK" || echo "✗ IAM list-roles FAILED"
echo

echo "=== EC2 Account Limits ==="
aws ec2 describe-account-attributes --attribute-names supported-platforms --region $AWS_REGION || true
echo

echo "=== Terraform Plan (GitHub Actions style) ==="
# Replicate the exact same plan command from GitHub Actions
terraform plan \
    -var="instance_type=t3.small" \
    -var="k3s_node_count=0" \
    -var="environment=gha-test" \
    -var="enable_monitoring=true" \
    -var="install_docker=false" \
    -var="resource_name_suffix=debug-$(date +%s)" \
    -var="vpc_id=" \
    -out=tfplan-debug

echo
echo "=== Plan Analysis ==="
terraform show -json tfplan-debug > tfplan-debug.json
echo "Plan contains $(jq -r '.resource_changes | length' tfplan-debug.json) resource changes"
echo "Resources to create: $(jq -r '[.resource_changes[] | select(.change.actions[0] == "create")] | length' tfplan-debug.json)"

echo
echo "=== Resource Breakdown ==="
echo "Resources by type:"
jq -r '.resource_changes[] | select(.change.actions[0] == "create") | .type' tfplan-debug.json | sort | uniq -c

echo
echo "=== VPC Resources Analysis ==="
echo "VPC-related resources to create:"
jq -r '.resource_changes[] | select(.change.actions[0] == "create" and (.type | contains("vpc") or .type | contains("subnet") or .type | contains("gateway") or .type | contains("route"))) | [.type, .name] | @tsv' tfplan-debug.json

echo
echo "=== IAM Resources Analysis ==="
echo "IAM-related resources to create:"
jq -r '.resource_changes[] | select(.change.actions[0] == "create" and (.type | contains("iam"))) | [.type, .name] | @tsv' tfplan-debug.json

echo
echo "=== Terraform Apply Test (DRY RUN) ==="
echo "Would you like to proceed with actual Terraform apply? (y/N)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Proceeding with Terraform apply..."
    timeout 480 terraform apply -auto-approve tfplan-debug 2>&1 | tee ../terraform-apply-debug.log
    ec=${PIPESTATUS[0]}
    echo "Apply exit code: $ec"
    if [ $ec -ne 0 ]; then
        echo "Apply failed - this matches the GitHub Actions behavior"
        echo "Last 50 lines of log:"
        tail -n 50 ../terraform-apply-debug.log
    else
        echo "Apply succeeded - this is different from GitHub Actions!"
        echo "Cleaning up resources..."
        terraform destroy -auto-approve
    fi
else
    echo "Skipping apply - plan analysis complete"
fi

echo
echo "=== Cleanup ==="
rm -f tfplan-debug tfplan-debug.json
echo "Debug script complete"
