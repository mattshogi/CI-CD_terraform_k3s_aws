# CI/CD Terraform k3s AWS

[![CI/CD Status](https://github.com/mattshogi/CI-CD_terraform_k3s_aws/actions/workflows/ci-cd.yml/badge.svg?branch=main)](https://github.com/mattshogi/CI-CD_terraform_k3s_aws/actions/workflows/ci-cd.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Terraform](https://img.shields.io/badge/Terraform-1.8%2B-blue.svg)](https://www.terraform.io/)

## Overview

Lightweight DevOps deployment demonstrating modern infrastructure practices with the following tech stack:

- **Infrastructure**: Terraform + AWS (VPC, EC2, Security Groups)
- **Container Orchestration**: k3s (lightweight Kubernetes)
- **Container Runtime**: Docker + containerd
- **Ingress**: Traefik (default) or optional nginx Ingress Controller
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

Primary workflow: `.github/workflows/ci-cd.yml`

Jobs include:

1. Go build & test
2. Docker image build & push (GHCR)
3. Terraform fmt / validate + TFLint
4. Helm lint / template
5. Security scan (Trivy) with gating on CRITICAL vulns
6. Integration tests (scripts)
7. (Main branch) Staging plan (no apply by default)
8. (Dispatch / tags) Production plan
9. Optional destroy jobs (dispatch inputs)
10. Ephemeral Apply & Validate (new) — run `terraform apply`, wait, HTTP validate endpoints, optionally auto-destroy

Ephemeral apply is triggered via `workflow_dispatch` inputs:

Inputs of interest:

- `run_apply` (true/false) — enable infra apply & validation
- `apply_environment` (staging|production label tag)
- `instance_type_override` (default t3.small)
- `enable_monitoring` (true/false)
- `destroy_after_apply` (true/false) — auto teardown after validation

Outputs / artifacts:

- `server_public_ip` (job output)
- `infra-apply-validation-<run_attempt>` artifact containing `validation/summary.md`

Validation performs repeated curl checks against:

- Root ingress (`http://<ip>/`)
- Hello NodePort (`:<30080>/`)
- Grafana NodePort (`:30030/` when monitoring enabled)
- Prometheus NodePort (`:30900/` when monitoring enabled)

Configure these repository secrets (names must match workflows):

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SSH_KEY_NAME` (EC2 key pair name)  
- `SSH_PRIVATE_KEY` (optional: for SSH diagnostics; corresponds to the public part of `AWS_SSH_KEY_NAME`)

Optional secrets / variables:

- `AWS_DEFAULT_REGION` (default `us-east-1` if omitted)
- `VULN_CRITICAL_THRESHOLD` (security gating; default 0)

Ephemeral apply usage:

1. Go to Actions → `CI/CD Pipeline` → Run workflow
2. Set `run_apply=true` (and adjust other inputs as needed)
3. Wait for `infra-apply-validate` job; note `server_public_ip` in job summary
4. Download validation artifact for endpoint results
5. If you set `destroy_after_apply=false`, remember to manually destroy later (`terraform destroy` or rerun with destroy flags)

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

After deployment (t3.small recommended when monitoring):

- **Hello World (Ingress)**: `http://<public_ip>/`
- **Hello World (NodePort)**: `http://<public_ip>:30080/`
- **Grafana (NodePort)**: `http://<public_ip>:30030/` (admin/admin; only if monitoring enabled)
- **Prometheus (NodePort)**: `http://<public_ip>:30900/` (only if monitoring enabled)

## Cost Optimization

Cost notes:

- `t3.micro` works for bare cluster + app
- Use `t3.small` (or larger) when `enable_monitoring=true` to avoid memory pressure / API timeouts
- Single-node keeps cost minimal
- Always destroy ephemeral infra you no longer need

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
2. **Instance Size / OOM**: Monitoring on `t3.micro` may cause k3s API instability — prefer `t3.small`+
3. **VPC Limits**: Use existing VPC by setting `vpc_id` in terraform.tfvars
4. **user_data Size**: Large inline scripts exceed 16KB; this repo fetches installer via `install_script_url` to stay small
5. **Terraform Template Escapes**: Use `$${VAR}` inside `templatefile()` for bash parameter expansions

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

The `ci-cd.yml` workflow high-level flow:

1. Build & test Go
2. Build & push image
3. Terraform / Helm lint & validate
4. Security scan (Trivy)
5. Integration tests
6. Staging / production plan (no apply by default)
7. Optional ephemeral apply & endpoint validation (dispatch input)
8. Optional destroy jobs

Endpoint validation summary artifact provides quick pass/fail on service availability.
