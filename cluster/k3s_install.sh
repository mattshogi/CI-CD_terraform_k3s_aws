#!/usr/bin/env bash
# Complete k3s installer with all dependencies
set -euo pipefail

# Avoid adding another tee here; user-data wrapper already redirects output
# Start banner
echo "[INFO] Starting k3s installation at $(date)"

# System information
echo "[INFO] System: $(uname -a)"
echo "[INFO] User: $(whoami)"
echo "[INFO] Environment variables: NODE_INDEX=${NODE_INDEX:-}, SERVER_IP=${SERVER_IP:-}, K3S_TOKEN=${K3S_TOKEN:-}"

# Optional feature flags (export in user-data before invoking if desired)
ENABLE_INGRESS_NGINX=${ENABLE_INGRESS_NGINX:-false}
ENABLE_MONITORING=${ENABLE_MONITORING:-false}
APP_IMAGE=${APP_IMAGE:-hashicorp/http-echo:0.2.3}
HELLO_NODE_PORT=${HELLO_NODE_PORT:-30080}

# Idempotency guard
if [ -f /tmp/k3s-install-complete ]; then
  echo "[INFO] Installation already completed earlier; exiting."
  exit 0
fi

wait_for_system() {
  echo "[INFO] Performing system readiness checks..."
  local max_boot_wait=120
  local waited=0
  while [ ! -f /var/lib/cloud/instance/boot-finished ] && [ $waited -lt $max_boot_wait ]; do
    echo "[INFO] Waiting for cloud-init final stage (boot-finished not present yet)... ($waited/${max_boot_wait}s)"
    sleep 5
    waited=$((waited+5))
  done
  if [ ! -f /var/lib/cloud/instance/boot-finished ]; then
    echo "[WARN] boot-finished marker still absent after ${max_boot_wait}s; continuing anyway."
  else
    echo "[INFO] boot-finished detected."
  fi

  # Wait for package locks with timeout
  local max_wait=300
  local wait_time=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [ $wait_time -ge $max_wait ]; then
      echo "[ERROR] Timeout waiting for package locks"
      exit 1
    fi
    echo "[INFO] Waiting for package locks... ($wait_time/${max_wait}s)"
    sleep 10
    wait_time=$((wait_time + 10))
  done
}

# Install system dependencies (keep minimal for small instances)
install_system_deps() {
  echo "[INFO] Installing system dependencies..."
  apt-get update -y
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

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker already installed"
    return 0
  fi
  echo "[INFO] Installing Docker..."
  apt-get install -y docker.io
  systemctl enable docker
  systemctl start docker
  usermod -aG docker ubuntu || true
  docker --version
  echo "[INFO] Docker installed successfully"
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "[INFO] Helm already installed"
    return 0
  fi
  echo "[INFO] Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version
  echo "[INFO] Helm installed successfully"
}

install_k3s() {
  echo "[INFO] Installing k3s..."
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    echo "[INFO] Installing k3s server..."
    local extra_exec="--write-kubeconfig-mode=644"
    if [ "${ENABLE_INGRESS_NGINX}" = "true" ]; then
      extra_exec="$extra_exec --disable traefik"
    fi
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$extra_exec" sh -s - server
  else
    echo "[INFO] Installing k3s agent..."
    if [ -z "${SERVER_IP:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
      echo "[ERROR] SERVER_IP and K3S_TOKEN required for agent installation"
      exit 1
    fi
    curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="$K3S_TOKEN" sh -
  fi
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

wait_for_traefik() {
  if [ "${ENABLE_INGRESS_NGINX}" = "true" ]; then
    # Using nginx instead; skip traefik wait
    return 0
  fi
  echo "[INFO] Waiting for Traefik ingress controller pods to be Ready..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local timeout=300
  local waited=0
  while true; do
    # Try multiple label selectors seen in k3s distributions
    ready_count=$(k3s kubectl get pods -n kube-system -l app=traefik --no-headers 2>/dev/null | awk '$2 ~ /1\/1/ {c++} END{print c+0}')
    total_count=$(k3s kubectl get pods -n kube-system -l app=traefik --no-headers 2>/dev/null | wc -l || echo 0)
    if [ "$total_count" -gt 0 ] && [ "$ready_count" -eq "$total_count" ]; then
      echo "[INFO] Traefik pods Ready ($ready_count/$total_count)"
      break
    fi
    if [ $waited -ge $timeout ]; then
      echo "[WARN] Traefik pods not all Ready after ${timeout}s; continuing anyway"
      break
    fi
    sleep 5; waited=$((waited+5))
  done
}

setup_helm_repos() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping Helm setup on agent node"
    return 0
  fi
  echo "[INFO] Setting up Helm repositories..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update || true
  echo "[INFO] Helm repositories configured"
}

install_ingress() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping ingress installation on agent node"
    return 0
  fi
  if [ "${ENABLE_INGRESS_NGINX}" != "true" ]; then
    echo "[INFO] ENABLE_INGRESS_NGINX=false; relying on bundled traefik"
    return 0
  fi
  echo "[INFO] Installing nginx ingress controller (overriding traefik)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local max_attempts=3
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    echo "[INFO] Ingress installation attempt $attempt/$max_attempts"
    if helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --create-namespace \
      --set controller.service.type=NodePort \
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

install_monitoring() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping monitoring installation on agent node"
    return 0
  fi
  if [ "${ENABLE_MONITORING}" != "true" ]; then
    echo "[INFO] ENABLE_MONITORING=false; skipping Prometheus/Grafana"
    return 0
  fi
  echo "[INFO] Installing Prometheus and Grafana (this may take several minutes)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.adminPassword=admin \
    --wait --timeout 15m || {
      echo "[WARN] Monitoring installation failed, continuing without monitoring"
      return 0
    }
  echo "[INFO] Monitoring stack installed successfully"
}

expose_monitoring() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    return 0
  fi
  if [ "${ENABLE_MONITORING}" != "true" ]; then
    return 0
  fi
  echo "[INFO] Exposing monitoring services via NodePort..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # Wait a bit for services to appear
  local waited=0
  while [ $waited -lt 120 ]; do
    if k3s kubectl get svc -n monitoring kube-prometheus-stack-grafana >/dev/null 2>&1; then
      break
    fi
    sleep 5; waited=$((waited+5))
  done
  # Patch Grafana
  if k3s kubectl get svc -n monitoring kube-prometheus-stack-grafana >/dev/null 2>&1; then
    k3s kubectl patch svc kube-prometheus-stack-grafana -n monitoring -p '{"spec":{"type":"NodePort","ports":[{"name":"service","port":80,"targetPort":3000,"protocol":"TCP","nodePort":30030}]}}' || true
  else
    echo "[WARN] Grafana service not found for patching"
  fi
  # Patch Prometheus (main service selection may vary; choose server service)
  if k3s kubectl get svc -n monitoring kube-prometheus-stack-prometheus >/dev/null 2>&1; then
    k3s kubectl patch svc kube-prometheus-stack-prometheus -n monitoring -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":9090,"targetPort":9090,"protocol":"TCP","nodePort":30900}]}}' || true
  else
    echo "[WARN] Prometheus service not found for patching"
  fi
  local ip
  ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "<unknown>")
  echo "[INFO] Monitoring endpoints (once ready):"
  echo "  - Grafana:    http://${ip}:30030/ (admin/admin)"
  echo "  - Prometheus: http://${ip}:30900/"
}

deploy_hello_world() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping application deployment on agent node"
    return 0
  fi
  echo "[INFO] Deploying Hello World application with image ${APP_IMAGE} (traefik or nginx ingress)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl create namespace hello-world || true
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
        image: ${APP_IMAGE}
        args:
        - "-text=Hello, World!"
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
    nodePort: ${HELLO_NODE_PORT}
  type: NodePort
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world
  namespace: hello-world
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  ingressClassName: traefik
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

  echo "[INFO] Root index deployment removed (using single hello-world ingress)"

  echo "[INFO] Waiting for Hello World pods to become Ready..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local waited=0
  local timeout=300
  local fallback_performed=false
  while [ $waited -lt $timeout ]; do
    not_ready=$(k3s kubectl get pods -n hello-world --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1] != a[2]) print $0}' | wc -l || echo 1)
    status_lines=$(k3s kubectl get pods -n hello-world --no-headers 2>/dev/null || true)
    if [ -n "$status_lines" ]; then
      echo "[DEBUG] hello-world pod status:\n$status_lines"
    fi
    # Detect ImagePullBackOff
    if echo "$status_lines" | grep -q 'ImagePullBackOff'; then
      if [ "$APP_IMAGE" != "hashicorp/http-echo:0.2.3" ] && [ "$fallback_performed" = false ]; then
        echo "[WARN] ImagePullBackOff detected for custom image $APP_IMAGE. Falling back to hashicorp/http-echo:0.2.3"
        cat <<FALLBACK | k3s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: hello-world
spec:
  replicas: 1
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
        - "-text=Hello, World fallback image!"
        ports:
        - containerPort: 5678
FALLBACK
        fallback_performed=true
        echo "[INFO] Applied fallback deployment; continuing to wait."
      fi
    fi
    if [ "$not_ready" -eq 0 ] && [ -n "$status_lines" ]; then
      echo "[INFO] Hello World pods Ready"
      break
    fi
    sleep 5
    waited=$((waited+5))
  done
  if [ $waited -ge $timeout ]; then
    echo "[WARN] Timeout waiting for Hello World pods to become Ready (continuing)." >&2
  fi

  echo "[INFO] Service endpoints (once Ready):"
  local node_ip
  node_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "<unknown>")
  echo "  - Ingress (traefik): http://${node_ip}/"
  echo "  - NodePort:          http://${node_ip}:${HELLO_NODE_PORT}/"

  echo "[INFO] Waiting for service endpoints registration..."
  local ep_wait=0
  while [ $ep_wait -lt 120 ]; do
    if k3s kubectl get ep -n hello-world hello-world -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -qE '.'; then
      echo "[INFO] Endpoints detected for hello-world service"; break
    fi
    sleep 5; ep_wait=$((ep_wait+5))
  done

  echo "[INFO] Performing in-cluster curl test via NodePort (loopback)..."
  if command -v curl >/dev/null 2>&1; then
    curl -s -m 5 "http://127.0.0.1:${HELLO_NODE_PORT}/" | head -n1 || true
  fi
  echo "[INFO] Capturing post-deploy diagnostic snapshot..."
  {
    echo "===== kubectl get nodes -o wide ====="; k3s kubectl get nodes -o wide || true;
    echo "===== kubectl get pods -A -o wide ====="; k3s kubectl get pods -A -o wide || true;
    echo "===== kubectl get svc -A ====="; k3s kubectl get svc -A || true;
    echo "===== kubectl get ingress -A ====="; k3s kubectl get ingress -A || true;
    echo "===== kubectl describe ingress hello-world -n hello-world ====="; k3s kubectl describe ingress hello-world -n hello-world || true;
    echo "===== kubectl get ep -n hello-world hello-world -o yaml ====="; k3s kubectl get ep -n hello-world hello-world -o yaml || true;
    echo "===== iptables -t nat -L KUBE-NODEPORTS -n -v ====="; iptables -t nat -L KUBE-NODEPORTS -n -v 2>/dev/null || true;
    echo "===== ss -tnlp | grep ${HELLO_NODE_PORT} (expect no direct listener; NodePort is iptables) ====="; ss -tnlp | grep ":${HELLO_NODE_PORT}" || true;
  } > /var/log/k3s_diagnostics_hello_world.txt 2>&1 || true
  echo "[INFO] Diagnostics written to /var/log/k3s_diagnostics_hello_world.txt"
}

finalize_installation() {
  echo "[INFO] Finalizing installation..."
  apt-get autoremove -y || true
  apt-get autoclean || true
  chmod 644 /etc/rancher/k3s/k3s.yaml || true
  echo "Installation completed at $(date)" > /tmp/k3s-install-complete
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    echo "[SUCCESS] k3s server installation completed!"
    local ip
    ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "<unknown>")
    echo "[INFO] Services available (once pods ready):"
    echo "  - Hello World: http://$ip/"
    [ "${ENABLE_MONITORING}" = "true" ] && echo "  - Prometheus/Grafana via NodePorts (cluster-local)"
    if [ -f /var/log/k3s_diagnostics_hello_world.txt ]; then
      echo "[INFO] === Embedded Hello World diagnostics snapshot (truncated to 300 lines) ==="
      tail -n 300 /var/log/k3s_diagnostics_hello_world.txt || true
      echo "[INFO] === End diagnostics snapshot ==="
    else
      echo "[INFO] Diagnostics snapshot file not found yet."
    fi
  else
    echo "[SUCCESS] k3s agent installation completed!"
  fi
}

main() {
  echo "[INFO] Starting k3s installation"
  echo "[INFO] Node Type: $([ "${NODE_INDEX:-0}" = "0" ] && echo "Server" || echo "Agent")"
  systemctl disable --now ufw 2>/dev/null || true
  wait_for_system
  install_system_deps
  install_docker
  install_helm
  install_k3s
  if [ "${NODE_INDEX:-0}" = "0" ]; then
    setup_helm_repos
    install_ingress
    install_monitoring
  wait_for_traefik
  expose_monitoring
    deploy_hello_world
  fi
  finalize_installation
}

trap 'echo "[ERROR] Installation failed at line $LINENO"' ERR
main "$@"
