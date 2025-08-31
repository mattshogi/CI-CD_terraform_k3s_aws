# GitHub Actions CI/CD Pipeline

This repository includes a comprehensive CI/CD pipeline built with GitHub Actions for the DevOps showcase project.

## 🔄 Workflows Overview

### 1. **Main CI/CD Pipeline** (`ci-cd.yml`)
**Triggers:** Push to `main`/`develop`, Pull Requests to `main`

**Jobs:**
- **test-app**: Tests the Go application
- **build-docker**: Builds and pushes Docker images to GitHub Container Registry
- **terraform-validate**: Validates Terraform configurations across all modules
- **helm-validate**: Validates and lints Helm charts
- **security-scan**: Runs Trivy vulnerability scanning
- **integration-tests**: Runs comprehensive integration tests
- **deploy-staging**: Validates staging deployment (on main branch)
- **deploy-production**: Validates production deployment (manual/tag trigger)

### 2. **Pull Request Validation** (`pr-validation.yml`)
**Triggers:** Pull Requests to `main`/`develop`

**Features:**
- Fast validation for PRs
- Terraform cost estimation
- Go tests and builds
- Docker image build testing
- Automatic PR comments with infrastructure cost estimates

### 3. **Release Management** (`release.yml`)
**Triggers:** Tag push (`v*`) or manual workflow dispatch

**Features:**
- Automatic changelog generation
- Multi-platform binary builds (Linux, macOS, Windows)
- Multi-architecture Docker images (amd64, arm64)
- GitHub Release creation with artifacts

### 4. **Dependency Updates** (`dependency-updates.yml`)
**Triggers:** Weekly schedule (Sundays 2 AM UTC) or manual

**Features:**
- Automated Go dependency updates
- Terraform provider updates
- Security auditing with `govulncheck`
- Automatic PR creation for updates

### 5. **Monitoring & Cleanup** (`monitoring.yml`)
**Triggers:** Daily schedule (3 AM UTC) or manual

**Features:**
- Container image cleanup (keeps latest 5 versions)
- Infrastructure health checks
- Daily security reports

## 🔧 Setup Instructions

### 1. Repository Secrets
Configure these secrets in GitHub Settings > Secrets and variables > Actions:

```bash
# Optional: For actual AWS deployments
AWS_ACCESS_KEY_ID          # AWS access key for deployments
AWS_SECRET_ACCESS_KEY      # AWS secret key for deployments
AWS_SSH_KEY_NAME          # Name of your AWS EC2 key pair
```

### 2. Container Registry
The pipeline uses GitHub Container Registry (ghcr.io) which requires:
- `GITHUB_TOKEN` (automatically provided)
- Package write permissions (automatically handled)

### 3. Environment Protection (Optional)
Set up environment protection rules:
1. Go to Settings > Environments
2. Create environments: `staging`, `production`
3. Add protection rules as needed

## 🚀 Pipeline Features

### **Multi-Platform Support**
- **Docker**: Linux amd64/arm64
- **Binaries**: Linux, macOS, Windows (amd64/arm64)

### **Security First**
- Vulnerability scanning with Trivy
- Go security auditing with govulncheck
- SARIF integration with GitHub Security tab
- Container image signing (optional)

### **Infrastructure as Code**
- Terraform validation and planning
- Multiple environment support
- Cost estimation for infrastructure changes
- Helm chart validation and testing

### **Quality Assurance**
- Automated testing at multiple levels
- Integration testing
- Docker build validation
- Terraform format checking

## 📊 Monitoring & Observability

### **Workflow Monitoring**
- All workflows include comprehensive logging
- Artifact uploads for build outputs
- Security scan results in GitHub Security tab

### **Cost Management**
- Infrastructure cost estimation on PRs
- Automated cleanup of old container images
- Resource optimization recommendations

## 🔄 Deployment Flow

### **Development Flow**
1. **PR Creation** → PR validation runs
2. **PR Merge to main** → Full CI/CD pipeline
3. **Staging Deployment** → Automatic validation
4. **Tag Creation** → Release process
5. **Production Deployment** → Manual approval required

### **Release Flow**
1. **Create Tag** (`git tag v1.0.0 && git push --tags`)
2. **Release Workflow** → Builds artifacts
3. **GitHub Release** → Created with changelog
4. **Production Deployment** → Optional manual trigger

## 🛠 Customization

### **Adding New Jobs**
```yaml
new-job:
  name: New Job
  runs-on: ubuntu-latest
  needs: [previous-job]
  steps:
    - uses: actions/checkout@v4
    - name: Your step
      run: echo "Hello World"
```

### **Environment Variables**
```yaml
env:
  CUSTOM_VAR: value
  REGISTRY: ghcr.io
```

### **Matrix Builds**
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, windows-latest, macos-latest]
    go-version: ['1.20', '1.21']
```

## 📚 Best Practices

1. **Security**: Never commit secrets, use GitHub Secrets
2. **Efficiency**: Use caching for dependencies
3. **Reliability**: Include retry logic for flaky operations
4. **Monitoring**: Use artifacts for important outputs
5. **Documentation**: Keep workflows well-documented

## 🚨 Troubleshooting

### **Common Issues**

**Docker Build Fails**
```bash
# Check Docker setup
docker build -t test ./app
```

**Terraform Validation Fails**
```bash
# Check formatting
terraform fmt -check -recursive .
```

**Go Tests Fail**
```bash
cd app
go mod download
go test -v ./...
```

### **Debugging Workflows**
1. Check workflow logs in Actions tab
2. Use `workflow_dispatch` for manual testing
3. Add debug steps with `run: env` to see environment
4. Use `actions/upload-artifact` for debugging files

## 📈 Metrics & Analytics

The pipeline provides insights into:
- Build success rates
- Deployment frequency
- Security scan results
- Test coverage trends
- Infrastructure costs

Access these through:
- GitHub Actions tab
- Security tab (for vulnerability reports)
- Insights tab (for general repository analytics)
