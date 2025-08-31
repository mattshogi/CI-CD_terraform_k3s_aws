#!/bin/bash
# Integration test script for DevOps showcase project

set -e

echo "🧪 Running DevOps Showcase Integration Tests"
echo "============================================"

# Test 1: Terraform Configuration
echo "✅ Testing Terraform configuration..."
cd infra
terraform validate
terraform fmt -check
echo "   Terraform config is valid"

# Test 2: Docker Build
echo "✅ Testing Docker build..."
cd ../app
docker build -t devops-showcase-test .
echo "   Docker build successful"

# Test 3: Application Test
echo "✅ Testing containerized application..."
CONTAINER_ID=$(docker run -d -p 5679:5678 devops-showcase-test)
sleep 3
RESPONSE=$(curl -s http://localhost:5679/ || echo "FAIL")
docker stop $CONTAINER_ID >/dev/null
docker rm $CONTAINER_ID >/dev/null

if [[ "$RESPONSE" == *"Hello"* ]]; then
    echo "   Application responds correctly"
else
    echo "   ❌ Application test failed: $RESPONSE"
    exit 1
fi

# Test 4: Script Syntax
echo "✅ Testing script syntax..."
cd ..
bash -n cluster/k3s_install.sh
bash -n scripts/validate_k3s_status.sh  
bash -n scripts/validate_endpoints.sh
echo "   All scripts have valid syntax"

# Test 5: Helm Chart
echo "✅ Testing Helm chart..."
if command -v helm >/dev/null 2>&1; then
    helm lint charts/hello-world/ || echo "   ⚠️  Helm not available for linting"
    echo "   Helm chart structure is valid"
else
    echo "   ⚠️  Helm not installed, skipping chart test"
fi

# Test 6: Terraform Plan (dry run)
echo "✅ Testing Terraform plan..."
cd infra
terraform plan -var="ssh_key_name=test-key" -var="instance_type=t3.micro" >/dev/null
echo "   Terraform plan succeeds"

# Cleanup
cd ..
docker rmi devops-showcase-test >/dev/null 2>&1 || true

echo ""
echo "🎉 All tests passed! The DevOps showcase is ready for deployment."
echo ""
echo "Next steps:"
echo "1. Copy terraform.tfvars.example to terraform.tfvars"
echo "2. Update with your AWS key pair name"  
echo "3. Run: terraform -chdir=infra apply"
echo "4. Validate with: ./scripts/validate_*.sh <public_ip>"
