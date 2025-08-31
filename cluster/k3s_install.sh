#!/usr/bin/env bash
# Complete k3s installer with all dependencies
set -euo pipefail

# Logging setup
exec > >(tee -a /var/log/cloud-init-output.log /var/log/user-data.log) 2>&1
echo "[INFO] Starting k3s installation at $(date)"

# System information
echo "[INFO] System: $(uname -a)"
echo "[INFO] User: $(whoami)"
echo "[INFO] Environment variables: NODE_INDEX=${NODE_INDEX:-}, SERVER_IP=${SERVER_IP:-}, K3S_TOKEN=${K3S_TOKEN:-}"

# Wait for system to be ready
wait_for_system() {
  echo "[INFO] Waiting for system to be ready..."
  while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
    echo "[INFO] Waiting for cloud-init to finish..."
    sleep 5
  done
  
  # Wait for package locks
  local max_wait=300
  local wait_time=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [ $wait_time -ge $max_wait ]; then
      echo "[ERROR] Timeout waiting for package locks"
      exit 1
    fi
    echo "[INFO] Waiting for package locks... ($wait_time/$max_wait)"
    sleep 10
    wait_time=$((wait_time + 10))
  done
}

# Install system dependencies
install_system_deps() {
  echo "[INFO] Installing system dependencies..."
  
  # Update package list
  apt-get update -y
  
  # Install essential packages
  apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    jq
    
  echo "[INFO] System dependencies installed"
}

# Install Docker
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker already installed"
    return 0
  fi
  
  echo "[INFO] Installing Docker..."
  
  # Install Docker from Ubuntu repositories (simpler and more reliable)
  apt-get install -y docker.io
  
  # Start and enable Docker
  systemctl enable docker
  systemctl start docker
  
  # Add ubuntu user to docker group
  usermod -aG docker ubuntu || true
  
  # Verify installation
  docker --version
  echo "[INFO] Docker installed successfully"
}

# Install Helm
install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "[INFO] Helm already installed"
    return 0
  fi
  
  echo "[INFO] Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  
  # Verify installation
  helm version
  echo "[INFO] Helm installed successfully"
}

# Install k3s
install_k3s() {
  echo "[INFO] Installing k3s..."
  
  # Determine if this is a server or agent
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    echo "[INFO] Installing k3s server..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -s - server
  else
    echo "[INFO] Installing k3s agent..."
    if [ -z "${SERVER_IP:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
      echo "[ERROR] SERVER_IP and K3S_TOKEN required for agent installation"
      exit 1
    fi
    curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="$K3S_TOKEN" sh -
  fi
  
  # Wait for k3s to be ready (only for server)
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    echo "[INFO] Waiting for k3s API server to be ready..."
    local max_wait=300
    local wait_time=0
    while ! k3s kubectl get nodes >/dev/null 2>&1; do
      if [ $wait_time -ge $max_wait ]; then
        echo "[ERROR] Timeout waiting for k3s API server"
        exit 1
      fi
      echo "[INFO] Waiting for k3s API... ($wait_time/$max_wait)"
      sleep 10
      wait_time=$((wait_time + 10))
    done
    echo "[INFO] k3s API server is ready"
  fi
}

# Setup Helm repositories (server only)
setup_helm_repos() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping Helm setup on agent node"
    return 0
  fi
  
  echo "[INFO] Setting up Helm repositories..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  
  # Add repositories with error handling
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update || true
  
  echo "[INFO] Helm repositories configured"
}

# Install ingress controller (server only)
install_ingress() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping ingress installation on agent node"
    return 0
  fi
  
  echo "[INFO] Installing nginx ingress controller..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  
  # Install with retry logic
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "[INFO] Ingress installation attempt $attempt/$max_attempts"
    
    if helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --create-namespace \
      --set controller.service.type=NodePort \
      --set controller.service.nodePorts.http=80 \
      --wait --timeout 10m; then
      echo "[INFO] Ingress controller installed successfully"
      return 0
    fi
    
    echo "[WARN] Ingress installation attempt $attempt failed"
    attempt=$((attempt + 1))
    sleep 30
  done
  
  echo "[ERROR] Failed to install ingress after $max_attempts attempts"
  return 1
}

# Install monitoring stack (server only)
install_monitoring() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping monitoring installation on agent node"
    return 0
  fi
  
  echo "[INFO] Installing Prometheus and Grafana..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  
  # Install with conservative resource settings for t3.micro
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort=9090 \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=3000 \
    --set grafana.adminPassword=admin \
    --set prometheus.prometheusSpec.resources.requests.memory=200Mi \
    --set prometheus.prometheusSpec.resources.limits.memory=400Mi \
    --set grafana.resources.requests.memory=100Mi \
    --set grafana.resources.limits.memory=200Mi \
    --wait --timeout 15m || {
      echo "[WARN] Monitoring installation failed, continuing without monitoring"
      return 0
    }
  
  echo "[INFO] Monitoring stack installed successfully"
}

# Deploy hello world application (server only)
deploy_hello_world() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping application deployment on agent node"
    return 0
  fi
  
  echo "[INFO] Deploying Hello World application..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  
  # Create namespace
  k3s kubectl create namespace hello-world || true
  
  # Deploy application with manifests
  cat <<EOF | k3s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: hello-world
  labels:
    app: hello-world
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
      - name: hello
        image: hashicorp/http-echo:0.2.3
        args:
        - "-text=Hello, World from k3s DevOps Showcase!"
        ports:
        - containerPort: 5678
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
  namespace: hello-world
  labels:
    app: hello-world
spec:
  selector:
    app: hello-world
  ports:
  - port: 80
    targetPort: 5678
    protocol: TCP
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world
  namespace: hello-world
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-world
            port:
              number: 80
EOF

  echo "[INFO] Hello World application deployed"
}

# Cleanup and finalization
finalize_installation() {
  echo "[INFO] Finalizing installation..."
  
  # Clean up package cache
  apt-get autoremove -y
  apt-get autoclean
  
  # Set proper permissions
  chmod 644 /etc/rancher/k3s/k3s.yaml || true
  
  # Create completion marker
  echo "Installation completed at $(date)" > /tmp/k3s-install-complete
  
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    echo "[SUCCESS] k3s server installation completed!"
    echo "[INFO] Services available at:"
    echo "  - Hello World: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)/"
    echo "  - Prometheus: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9090"
    echo "  - Grafana: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000 (admin/admin)"
  else
    echo "[SUCCESS] k3s agent installation completed!"
  fi
}

# Main installation flow
main() {
  echo "[INFO] Starting DevOps Showcase k3s installation"
  echo "[INFO] Node Type: $([ "${NODE_INDEX:-0}" = "0" ] && echo "Server" || echo "Agent")"
  
  # Disable firewall for simplicity
  systemctl disable --now ufw 2>/dev/null || true
  
  # Run installation steps
  wait_for_system
  install_system_deps
  install_docker
  install_helm
  install_k3s
  
  # Server-only components
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    setup_helm_repos
    install_ingress
    install_monitoring
    deploy_hello_world
  fi
  
  finalize_installation
}

# Error handling
trap 'echo "[ERROR] Installation failed at line $LINENO"' ERR

# Run main function
main "$@"
