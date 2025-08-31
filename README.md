# CI/CD Terraform k3s AWS

[![CI/CD Status](https://github.com/mattshogi/CI-CD_terraform_k3s_aws/actions/workflows/ci-cd.yml/badge.svg?branch=main)](https://github.com/mattshogi/CI-CD_terraform_k3s_aws/actions/workflows/ci-cd.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Terraform](https://img.shields.io/badge/Terraform-1.8%2B-blue.svg)](https://www.terraform.io/)

## Overview

Lightweight DevOps deployment demonstrating modern infrastructure practices with the following tech stack:

- **Infrastructure**: Terraform + AWS (VPC, EC2, Security Groups)
- **Container Orchestration**: k3s (lightweight Kubernetes)
- **Container Runtime**: Docker + containerd
- **Service Mesh**: nginx Ingress Controller
- **Monitoring**: Prometheus + Grafana
- **CI/CD**: GitHub Actions
- **Application**: Go-based Hello World service

## Architecture

```text
AWS VPC
└── Public Subnet
    └── EC2 Instance (k3s)
        ├── nginx Ingress Controller (port 80)
        ├── Hello World App
        ├── Prometheus (port 9090)
        └── Grafana (port 3000)
```

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- An existing EC2 Key Pair in your AWS region
- Terraform 1.8+ installed locally (optional for GitHub Actions)

### Local Deployment

```bash
# Clone and configure
git clone <repo-url>
cd CI-CD_terraform_k3s_aws
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your EC2 key pair name

# Deploy infrastructure
terraform -chdir=infra init
terraform -chdir=infra plan
terraform -chdir=infra apply

# Get connection info and validate
terraform -chdir=infra output server_public_ip
./scripts/validate_k3s_status.sh <server_ip>
./scripts/validate_endpoints.sh <server_ip>
```

### GitHub Actions Deployment

Configure these repository secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `SSH_KEY_NAME` (your EC2 key pair name)
- `SSH_PRIVATE_KEY` (private key content for validation)

Then manually trigger the "Deploy k3s Cluster" workflow.

## Project Structure

```text
├── infra/                  # Terraform infrastructure code
│   ├── main.tf            # Main infrastructure resources
│   └── outputs.tf         # Infrastructure outputs
├── cluster/               # k3s installation scripts
│   ├── k3s_install.sh     # Main installer script
│   └── user_data.tpl      # EC2 user data template
├── app/                   # Hello World application
│   ├── main.go           # Go application code
│   ├── Dockerfile        # Container definition
│   └── go.mod            # Go module definition
├── charts/hello-world/    # Helm chart for application
└── scripts/              # Validation and utility scripts
```

## Services Access

After deployment, access services via the EC2 public IP:

- **Hello World**: `http://<public_ip>/`
- **Prometheus**: `http://<public_ip>:9090`
- **Grafana**: `http://<public_ip>:3000` (admin/admin)

## Cost Optimization

This project is designed for AWS Free Tier:

- Uses `t3.micro` instances by default
- Single-node k3s cluster (no additional agents)
- Minimal resource allocations for monitoring stack
- Clean teardown with `terraform destroy`

## Validation Scripts

The project includes automated validation:

- `scripts/validate_k3s_status.sh <ip>` - Checks cluster health
- `scripts/validate_endpoints.sh <ip>` - Tests service endpoints

## Cleanup

```bash
terraform -chdir=infra destroy
```

## Troubleshooting

### Common Issues

1. **SSH Key Issues**: Ensure your EC2 key pair exists and private key is accessible
2. **Instance Size**: If monitoring stack fails, try `t3.small` instead of `t3.micro`
3. **VPC Limits**: Use existing VPC by setting `vpc_id` in terraform.tfvars

### Logs

Check these locations on the EC2 instance:

- `/var/log/cloud-init-output.log` - Cloud-init execution
- `/var/log/user-data.log` - User data script output
- `sudo journalctl -u k3s` - k3s service logs

## Development

### Local Testing

```bash
# Test Go application locally
cd app
go run main.go

# Test with Docker
docker build -t hello-local .
docker run -p 5678:5678 hello-local
```

### Integration Testing

Run the full test suite to validate all components:

```bash
./test-integration.sh
```

This tests:

- Terraform configuration validity
- Docker build process
- Application functionality
- Script syntax
- Helm chart structure
- Infrastructure planning

### CI/CD Workflow

The GitHub Actions workflow:

1. **Plan**: Runs `terraform plan` on every push
2. **Apply**: Runs `terraform apply` only on manual trigger
3. **Validate**: Tests endpoints and cluster health
4. **Cleanup**: Optional destroy step (manual only)
