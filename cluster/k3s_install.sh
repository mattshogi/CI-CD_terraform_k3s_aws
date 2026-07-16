#!/usr/bin/env bash
# Complete k3s installer with all dependencies
set -euo pipefail

# Avoid adding another tee here; user-data wrapper already redirects output
# Start banner
echo "[INFO] Starting k3s installation at $(date)"

# System information (never log secret values — only whether they are set)
echo "[INFO] System: $(uname -a)"
echo "[INFO] User: $(whoami)"
echo "[INFO] Environment: NODE_INDEX=${NODE_INDEX:-}, SERVER_IP=${SERVER_IP:-}, K3S_TOKEN=$([ -n "${K3S_TOKEN:-}" ] && echo '<set>' || echo '<unset>')"

# Optional feature flags (export in user-data before invoking if desired)
ENABLE_INGRESS_NGINX=${ENABLE_INGRESS_NGINX:-false}
ENABLE_MONITORING=${ENABLE_MONITORING:-false}
ENABLE_TLS=${ENABLE_TLS:-false}
ENABLE_GITOPS=${ENABLE_GITOPS:-false}
GITOPS_REPO_URL=${GITOPS_REPO_URL:-}
GITOPS_REF=${GITOPS_REF:-main}
APP_IMAGE=${APP_IMAGE:-hashicorp/http-echo:0.2.3}
HELLO_NODE_PORT=${HELLO_NODE_PORT:-30080}
INSTALL_DOCKER=${INSTALL_DOCKER:-false}
REPO_TARBALL_URL=${REPO_TARBALL_URL:-}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-}
HA_MODE=${HA_MODE:-false}
CLUSTER_INIT=${CLUSTER_INIT:-false}
SERVER_JOIN_URL=${SERVER_JOIN_URL:-}
TLS_HOST=${TLS_HOST:-}
CHART_DIR=/opt/repo-src/charts/hello-world

# Idempotency guard
if [ -f /tmp/k3s-install-complete ]; then
  echo "[INFO] Installation already completed earlier; exiting."
  exit 0
fi

# Instance metadata via IMDSv2 (the instance enforces http_tokens=required)
imds_get() {
  local path=$1 token
  token=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
  curl -s -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null || echo "<unknown>"
}

wait_for_system() {
  echo "[INFO] Performing system readiness checks..."
  local max_boot_wait=90
  local waited=0
  while [ ! -f /var/lib/cloud/instance/boot-finished ] && [ $waited -lt $max_boot_wait ]; do
    echo "[INFO] Waiting cloud-init (boot-finished missing)... ($waited/${max_boot_wait}s)"
    sleep 5; waited=$((waited+5))
  done
  if [ ! -f /var/lib/cloud/instance/boot-finished ]; then
    echo "[WARN] Proceeding without boot-finished; continuing"
  else
    echo "[INFO] boot-finished detected"
  fi
  # Defer heavy package installs until after k3s so we don't block service startup
}

# Install system dependencies (keep minimal for small instances)
install_system_deps() {
  echo "[INFO] Installing minimal deps pre-k3s (curl jq)"
  apt-get update -y
  apt-get install -y curl jq
  echo "[INFO] Minimal deps installed"
}

setup_swap() {
  local swap_size_mb=512
  if [ -f /swapfile ]; then
    echo "[INFO] Swapfile already present"
    return 0
  fi
  echo "[INFO] Creating ${swap_size_mb}MB swapfile to mitigate memory pressure..."
  fallocate -l ${swap_size_mb}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=${swap_size_mb}
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "[INFO] Swap active: $(swapon --show | tail -n +2 | awk '{print $1, $3}')"
}

install_docker() {
  if [ "${INSTALL_DOCKER}" != "true" ]; then
    echo "[INFO] Skipping Docker installation (INSTALL_DOCKER=${INSTALL_DOCKER})"
    return 0
  fi
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
  echo "[INFO] Installing k3s (early)";
  # kubeconfig stays root-only (default 600); everything here runs as root

  # Traefik-disable applies to every SERVER branch (HA primary, HA joining,
  # single server); nginx ingress replaces it when ENABLE_INGRESS_NGINX=true.
  local extra_exec=""
  if [ "${ENABLE_INGRESS_NGINX}" = "true" ]; then
    extra_exec="--disable traefik"
  fi
  # On Packer-baked AMIs the binary and airgap images are pre-installed; the
  # installer then only generates the service unit with our flags. This
  # detection must apply to every branch below.
  local skip_download="false"
  if command -v k3s >/dev/null 2>&1; then
    echo "[INFO] Baked k3s binary detected ($(k3s --version | head -1)); skipping download"
    skip_download="true"
  fi

  # is_server: this node runs the k3s API locally (all branches except legacy
  # agent) → gets the wait-for-API loop afterwards.
  # is_joining_server: additionally waits until it registers Ready in the etcd
  # cluster before deployment work proceeds elsewhere.
  local is_server="true"
  local is_joining_server="false"

  if [ "${CLUSTER_INIT}" = "true" ]; then
    # (a) HA primary — initialise the embedded-etcd cluster. K3S_TOKEN is
    # exported so the cluster join token is fixed and joining servers can
    # authenticate against a known value.
    echo "[INFO] Installing k3s as HA primary server (--cluster-init)..."
    if [ -z "${K3S_TOKEN:-}" ]; then
      echo "[ERROR] K3S_TOKEN required for HA --cluster-init; refusing to start with an unset token" >&2
      exit 1
    fi
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_SKIP_DOWNLOAD="$skip_download" \
      K3S_TOKEN="$K3S_TOKEN" \
      INSTALL_K3S_EXEC="--cluster-init $extra_exec" sh -s - server
  elif [ -n "${SERVER_JOIN_URL:-}" ]; then
    # (b) HA joining server — wait for the primary API to answer, then join
    # the etcd cluster as an additional control-plane node.
    echo "[INFO] Installing k3s as HA joining server (--server ${SERVER_JOIN_URL})..."
    if [ -z "${K3S_TOKEN:-}" ]; then
      echo "[ERROR] K3S_TOKEN required to join HA cluster; refusing to start with an unset token" >&2
      exit 1
    fi
    # k3s answers /ping unauthenticated once its API is up; poll ~10 minutes.
    echo "[INFO] Waiting for HA primary API at ${SERVER_JOIN_URL}/ping..."
    local join_wait=0 join_timeout=600
    until curl -sk --max-time 5 "${SERVER_JOIN_URL}/ping" >/dev/null 2>&1; do
      if [ "$join_wait" -ge "$join_timeout" ]; then
        echo "[ERROR] HA primary at ${SERVER_JOIN_URL} never answered /ping after ${join_timeout}s; aborting join" >&2
        exit 1
      fi
      echo "[INFO] Waiting for HA primary API... ($join_wait/$join_timeout)"
      sleep 10; join_wait=$((join_wait+10))
    done
    echo "[INFO] HA primary API answered; joining the cluster"
    is_joining_server="true"
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_SKIP_DOWNLOAD="$skip_download" \
      K3S_TOKEN="$K3S_TOKEN" \
      INSTALL_K3S_EXEC="--server ${SERVER_JOIN_URL} $extra_exec" sh -s - server
  elif [ "${HA_MODE}" != "true" ] && [ "${NODE_INDEX:-0}" != "0" ]; then
    # (c) Legacy agent path — kept exactly as before.
    echo "[INFO] Installing k3s agent..."
    is_server="false"
    if [ -z "${SERVER_IP:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
      echo "[ERROR] SERVER_IP and K3S_TOKEN required for agent installation"
      exit 1
    fi
    curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="$K3S_TOKEN" sh -
  else
    # (d) Single server — today's default behaviour (byte-for-byte).
    echo "[INFO] Installing k3s server..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_DOWNLOAD="$skip_download" INSTALL_K3S_EXEC="$extra_exec" sh -s - server
  fi

  if [ "$is_server" = "true" ]; then
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

    if [ "$is_joining_server" = "true" ]; then
      # Wait until this node registers Ready in the cluster before finalize.
      local this_host
      this_host=$(imds_get local-hostname)
      if [ -z "$this_host" ] || [ "$this_host" = "<unknown>" ]; then
        this_host=$(hostname)
      fi
      # k3s registers nodes under the short hostname.
      this_host="${this_host%%.*}"
      echo "[INFO] Waiting for joining server node '${this_host}' to become Ready..."
      local node_wait=0 node_timeout=300
      while true; do
        if k3s kubectl get nodes "${this_host}" --no-headers 2>/dev/null | awk '$2 ~ /Ready/' | grep -q .; then
          echo "[INFO] Joining server node '${this_host}' is Ready"
          break
        fi
        if [ "$node_wait" -ge "$node_timeout" ]; then
          echo "[WARN] Joining server node '${this_host}' not Ready after ${node_timeout}s; continuing"
          break
        fi
        sleep 10; node_wait=$((node_wait+10))
      done
    fi
  fi
}

wait_for_core_components() {
  echo "[INFO] Waiting for core Kubernetes components (node Ready, coredns, traefik svc)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local timeout=300
  local waited=0
  while [ $waited -lt $timeout ]; do
    local node_ready coredns_ready traefik_svc
    node_ready=$(k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/' | wc -l || echo 0)
    coredns_ready=$(k3s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '$2 ~ /1\/1/' | wc -l || echo 0)
    traefik_svc=$(k3s kubectl get svc -n kube-system traefik -o name 2>/dev/null || true)
    if [ "$node_ready" -ge 1 ] && [ "$coredns_ready" -ge 1 ] && { [ "${ENABLE_INGRESS_NGINX}" = "true" ] || [ -n "$traefik_svc" ]; }; then
      echo "[INFO] Core components ready (node_ready=$node_ready coredns_ready=$coredns_ready traefik_svc=${traefik_svc:-absent})"
      return 0
    fi
    if (( waited % 30 == 0 )); then
      echo "[DEBUG] core status waited=${waited}s node_ready=$node_ready coredns_ready=$coredns_ready traefik_svc=${traefik_svc:-absent}"
      k3s kubectl get pods -n kube-system --no-headers 2>/dev/null | head -n 20 || true
    fi
    sleep 5; waited=$((waited+5))
  done
  echo "[WARN] Timed out waiting for core components; continuing"
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
    ready_count=$(k3s kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | awk '$2 ~ /1\/1/ {c++} END{print c+0}')
    total_count=$(k3s kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l || echo 0)
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
  if [ "${ENABLE_TLS}" = "true" ]; then
    helm repo add jetstack https://charts.jetstack.io || true
  fi
  if [ "${ENABLE_GITOPS}" = "true" ]; then
    helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts || true
  fi
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
  if [ -z "${GRAFANA_ADMIN_PASSWORD}" ]; then
    echo "[WARN] No Grafana password provided; generating a random one (retrieve via: kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
    GRAFANA_ADMIN_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
  fi
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
    --set prometheus.service.nodePort=30900 \
    --set prometheus.service.type=NodePort \
    --set grafana.service.nodePort=30030 \
    --set grafana.service.type=NodePort \
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
  echo "[INFO] Exposing monitoring services via NodePort (robust mode)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local grafana_svc="kube-prometheus-stack-grafana"
  local prom_svc="kube-prometheus-stack-prometheus"
  local grafana_node_port=30030
  local prom_node_port=30900
  local timeout=600
  local interval=5
  local start_ts=$SECONDS
  local log_file=/var/log/k3s_monitoring_expose.log
  echo "[INFO] Waiting (up to ${timeout}s) for monitoring services to appear" | tee -a "$log_file"
  while [ $((SECONDS-start_ts)) -lt $timeout ]; do
    local have_graf have_prom
    k3s kubectl get svc -n monitoring "$grafana_svc" >/dev/null 2>&1 && have_graf=1 || have_graf=0
    k3s kubectl get svc -n monitoring "$prom_svc"    >/dev/null 2>&1 && have_prom=1 || have_prom=0
    echo "[DEBUG] monitoring svc presence: grafana=$have_graf prom=$have_prom waited=$((SECONDS-start_ts))s" | tee -a "$log_file"
    if [ $have_graf -eq 1 ] && [ $have_prom -eq 1 ]; then
      break
    fi
    sleep "$interval"
  done
  if ! k3s kubectl get svc -n monitoring "$grafana_svc" >/dev/null 2>&1; then
    echo "[WARN] Grafana service not found after wait window" | tee -a "$log_file"
  fi
  if ! k3s kubectl get svc -n monitoring "$prom_svc" >/dev/null 2>&1; then
    echo "[WARN] Prometheus service not found after wait window" | tee -a "$log_file"
  fi

  # Patch loop function
  patch_to_nodeport() {
    local svc=$1; shift
    local patch_json=$1; shift
    local target_port=$1; shift
    local attempts=0 max_attempts=8
    while [ $attempts -lt $max_attempts ]; do
      if ! k3s kubectl get svc -n monitoring "$svc" >/dev/null 2>&1; then
        attempts=$((attempts+1)); sleep 5; continue
      fi
      if k3s kubectl get svc -n monitoring "$svc" -o jsonpath='{.spec.type}' 2>/dev/null | grep -q NodePort; then
        echo "[INFO] $svc already NodePort" | tee -a "$log_file"; return 0
      fi
      if k3s kubectl patch svc "$svc" -n monitoring -p "$patch_json" >/dev/null 2>&1; then
        echo "[INFO] Patched $svc to NodePort (attempt $((attempts+1)))" | tee -a "$log_file"; return 0
      fi
      echo "[WARN] Patch attempt $((attempts+1)) for $svc failed" | tee -a "$log_file"
      attempts=$((attempts+1)); sleep 8
    done
    echo "[ERROR] Failed to patch $svc to NodePort after $max_attempts attempts" | tee -a "$log_file"
    return 1
  }

  patch_to_nodeport "$grafana_svc" '{"spec":{"type":"NodePort","ports":[{"name":"service","port":80,"targetPort":3000,"protocol":"TCP","nodePort":30030}]}}' 3000 || true
  patch_to_nodeport "$prom_svc" '{"spec":{"type":"NodePort","ports":[{"name":"http","port":9090,"targetPort":9090,"protocol":"TCP","nodePort":30900}]}}' 9090 || true

  # Capture final service specs
  { echo "===== FINAL monitoring services ====="; k3s kubectl get svc -n monitoring || true; echo "===== Grafana YAML ====="; k3s kubectl get svc "$grafana_svc" -n monitoring -o yaml || true; echo "===== Prometheus YAML ====="; k3s kubectl get svc "$prom_svc" -n monitoring -o yaml || true; } >> "$log_file" 2>&1 || true

  local ip
  ip=$(imds_get public-ipv4)
  echo "[INFO] Monitoring endpoints (once pods Ready):" | tee -a "$log_file"
  echo "  - Grafana:    http://${ip}:${grafana_node_port}/ (user: admin; password: see Grafana secret / SSM parameter)" | tee -a "$log_file"
  echo "  - Prometheus: http://${ip}:${prom_node_port}/" | tee -a "$log_file"
}

install_cert_manager() {
  if [ "${NODE_INDEX:-0}" != "0" ] || [ "${ENABLE_TLS}" != "true" ]; then
    return 0
  fi
  echo "[INFO] Installing cert-manager (self-signed ClusterIssuer)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 5m || {
    echo "[WARN] cert-manager install failed; continuing without TLS" >&2
    ENABLE_TLS=false
    return 0
  }
  # Self-signed issuer: demonstrates the full cert-manager machinery with no
  # external DNS/domain dependency (ephemeral IPs). For a real domain, add a
  # ClusterIssuer with an ACME (Let's Encrypt) solver and reference it in the
  # ingress annotation instead.
  cat <<'ISSUER' | k3s kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
ISSUER
  echo "[INFO] cert-manager ready; ClusterIssuer 'selfsigned' created"
}

install_flux() {
  if [ "${NODE_INDEX:-0}" != "0" ] || [ "${ENABLE_GITOPS}" != "true" ]; then
    return 0
  fi
  echo "[INFO] Installing Flux (source + helm controllers only)..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  helm upgrade --install flux2 fluxcd-community/flux2 \
    --namespace flux-system --create-namespace \
    --set kustomizeController.create=false \
    --set notificationController.create=false \
    --set imageAutomationController.create=false \
    --set imageReflectionController.create=false \
    --wait --timeout 5m || {
    echo "[WARN] Flux install failed; app deploy will fall back to direct Helm" >&2
    ENABLE_GITOPS=false
    return 0
  }
  echo "[INFO] Flux controllers ready"
}

# Fetch the repo source tarball at the pinned ref so the Helm chart deployed
# on the instance is the exact chart version Terraform planned against.
fetch_chart_source() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    return 0
  fi
  if [ -z "${REPO_TARBALL_URL}" ]; then
    echo "[WARN] REPO_TARBALL_URL not provided; chart deployment will fail"
    return 0
  fi
  echo "[INFO] Fetching chart source from ${REPO_TARBALL_URL}"
  mkdir -p /opt/repo-src
  local attempt
  for attempt in 1 2 3; do
    if curl -fsSL "${REPO_TARBALL_URL}" -o /tmp/repo-src.tar.gz; then
      tar -xzf /tmp/repo-src.tar.gz --strip-components=1 -C /opt/repo-src
      echo "[INFO] Chart source extracted to /opt/repo-src (attempt $attempt)"
      return 0
    fi
    echo "[WARN] Tarball download attempt $attempt failed"
    sleep $((attempt * 2))
  done
  echo "[ERROR] Failed to fetch chart source after retries" >&2
  return 1
}

# Direct push-time install. Relies on bash dynamic scoping for image_repo /
# image_tag set in deploy_hello_world.
deploy_with_helm() {
  echo "[INFO] Deploying hello-world via Helm (image ${APP_IMAGE}, nodePort ${HELLO_NODE_PORT}, tls=${ENABLE_TLS})"
  # In HA mode run two replicas so the chart's topologySpreadConstraints + PDB
  # (keyed off replicaCount>1) spread the app across nodes.
  local replica_args=()
  if [ "${HA_MODE}" = "true" ]; then
    replica_args+=(--set replicaCount=2)
  fi
  if helm upgrade --install hello-world "${CHART_DIR}" \
    --namespace hello-world --create-namespace \
    --set image.repository="${image_repo}" \
    --set image.tag="${image_tag}" \
    --set service.nodePort="${HELLO_NODE_PORT}" \
    "${replica_args[@]}" \
    -f /tmp/tls-values.yaml \
    --wait --timeout 5m; then
    echo "[INFO] hello-world deployed"
    return 0
  fi
  # Covers ImagePullBackOff (e.g. GHCR unreachable) and probe failures:
  # redeploy with a public fallback image that serves the same greeting.
  echo "[WARN] Deploy with ${APP_IMAGE} failed; falling back to hashicorp/http-echo" >&2
  cat > /tmp/fallback-values.yaml <<'VALUES'
image:
  repository: hashicorp/http-echo
  tag: "0.2.3"
args: ["-text=Hello, World! (fallback image)"]
probes:
  path: /
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 100
  runAsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
VALUES
  helm upgrade --install hello-world "${CHART_DIR}" \
    --namespace hello-world --create-namespace \
    -f /tmp/fallback-values.yaml \
    -f /tmp/tls-values.yaml \
    --set service.nodePort="${HELLO_NODE_PORT}" \
    "${replica_args[@]}" \
    --wait --timeout 3m || {
    echo "[ERROR] Fallback deployment also failed" >&2
    return 1
  }
  echo "[INFO] Fallback hello-world deployed"
}

# GitOps path: Flux reconciles the chart from the git repo itself. Uses
# dynamic scoping for image_repo / image_tag from deploy_hello_world.
deploy_with_flux() {
  if [ -z "${GITOPS_REPO_URL}" ]; then
    echo "[WARN] GITOPS_REPO_URL not set" >&2
    return 1
  fi
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # Pin to a commit when the ref is a full SHA (ephemeral reproducibility);
  # track the branch otherwise (continuous drift-corrected reconciliation).
  local ref_line
  if [[ "${GITOPS_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    ref_line="commit: ${GITOPS_REF}"
  else
    ref_line="branch: ${GITOPS_REF}"
  fi
  local tls_values=""
  if [ "${ENABLE_TLS}" = "true" ] && [ -s /tmp/tls-values.yaml ]; then
    tls_values=$(sed 's/^/    /' /tmp/tls-values.yaml)
  fi
  # In HA mode run two replicas (chart topologySpreadConstraints + PDB key off
  # replicaCount>1). Indented to sit under HelmRelease .spec.values.
  local replica_values=""
  if [ "${HA_MODE}" = "true" ]; then
    replica_values="    replicaCount: 2"
  fi
  echo "[INFO] Applying Flux GitRepository + HelmRelease (ref: ${ref_line})"
  cat <<FLUX | k3s kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: app-repo
  namespace: flux-system
spec:
  interval: 1m
  url: ${GITOPS_REPO_URL}
  ref:
    ${ref_line}
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: hello-world
  namespace: flux-system
spec:
  interval: 1m
  releaseName: hello-world
  targetNamespace: hello-world
  install:
    createNamespace: true
  chart:
    spec:
      chart: charts/hello-world
      reconcileStrategy: Revision
      sourceRef:
        kind: GitRepository
        name: app-repo
  values:
    image:
      repository: ${image_repo}
      tag: "${image_tag}"
    service:
      nodePort: ${HELLO_NODE_PORT}
${replica_values}
${tls_values}
FLUX
  echo "[INFO] Waiting for Flux to reconcile the release..."
  local waited=0 timeout=300
  while [ $waited -lt $timeout ]; do
    if k3s kubectl -n hello-world rollout status deploy/hello-world --timeout=10s >/dev/null 2>&1; then
      echo "[INFO] HelmRelease reconciled; deployment ready"
      return 0
    fi
    if (( waited % 60 == 0 )) && [ $waited -gt 0 ]; then
      k3s kubectl -n flux-system get gitrepository,helmrelease 2>/dev/null || true
    fi
    sleep 10; waited=$((waited+10))
  done
  echo "[WARN] Flux did not reconcile within ${timeout}s" >&2
  k3s kubectl -n flux-system describe helmrelease hello-world 2>/dev/null | tail -20 || true
  return 1
}

deploy_hello_world() {
  if [ "${NODE_INDEX:-0}" != "0" ]; then
    echo "[INFO] Skipping application deployment on agent node"
    return 0
  fi
  if [ ! -d "${CHART_DIR}" ]; then
    echo "[ERROR] Chart directory ${CHART_DIR} missing; cannot deploy application" >&2
    return 1
  fi
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # Split repository:tag for the chart's image values
  local image_repo="${APP_IMAGE%:*}"
  local image_tag="${APP_IMAGE##*:}"
  # TLS values: certificate for <public-ip>.sslip.io (wildcard DNS → this
  # host resolves to the instance with no DNS setup). The hostless HTTP rule
  # keeps plain http://<ip>/ working alongside.
  : > /tmp/tls-values.yaml
  if [ "${ENABLE_TLS}" = "true" ]; then
    local public_ip tls_host
    if [ -n "${TLS_HOST:-}" ]; then
      # HA mode passes the NLB DNS name; use it verbatim.
      tls_host="${TLS_HOST}"
    else
      public_ip=$(imds_get public-ipv4)
      tls_host="${public_ip}.sslip.io"
    fi
    cat > /tmp/tls-values.yaml <<TLSVALUES
ingress:
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
  tls:
    - hosts: ["${tls_host}"]
      secretName: hello-world-tls
TLSVALUES
    echo "[INFO] TLS enabled for https://${tls_host}/"
  fi
  if [ "${ENABLE_GITOPS}" = "true" ]; then
    if deploy_with_flux; then
      echo "[INFO] hello-world reconciled by Flux"
    else
      echo "[WARN] GitOps reconciliation failed; falling back to direct Helm install" >&2
      deploy_with_helm || return 1
    fi
  else
    deploy_with_helm || return 1
  fi

  echo "[INFO] Service endpoints (once Ready):"
  local node_ip
  node_ip=$(imds_get public-ipv4)
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
  # kubeconfig contains the cluster admin credential — keep it root-only
  chmod 600 /etc/rancher/k3s/k3s.yaml || true
  echo "Installation completed at $(date)" > /tmp/k3s-install-complete
  if [ -n "${SERVER_JOIN_URL:-}" ]; then
    # HA joining server: control-plane/etcd member only — no app/monitoring
    # deployment work happens here (that is gated to node 0).
    echo "[SUCCESS] k3s HA server joined the cluster!"
    echo "[INFO] This node is an additional control-plane/etcd member; application workloads are scheduled cluster-wide from the primary."
  elif [ "${NODE_INDEX:-0}" = "0" ]; then
    if [ "${HA_MODE}" = "true" ]; then
      echo "[SUCCESS] k3s HA primary server installation completed!"
    else
      echo "[SUCCESS] k3s server installation completed!"
    fi
    local ip
    ip=$(imds_get public-ipv4)
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
  echo "[INFO] Creating /tmp/k3s-ready marker"; touch /tmp/k3s-ready || true
}

wait_for_hello_world_ingress() {
  echo "[INFO] Waiting for hello-world ingress to be admitted..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local timeout=180 waited=0
  while [ $waited -lt $timeout ]; do
    if k3s kubectl get ingress -n hello-world hello-world >/dev/null 2>&1; then
      local backend
      backend=$(k3s kubectl get ingress -n hello-world hello-world -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' 2>/dev/null || true)
      if [ -n "$backend" ]; then
        echo "[INFO] Ingress backend resolved: $backend"
        return 0
      fi
    fi
    sleep 5; waited=$((waited+5))
  done
  echo "[WARN] Ingress not ready after ${timeout}s"
  return 1
}

wait_for_nodeport_rule() {
  echo "[INFO] Checking for NodePort ${HELLO_NODE_PORT} iptables rule..."
  local timeout=180 waited=0
  while [ $waited -lt $timeout ]; do
    if iptables -t nat -L KUBE-NODEPORTS -n 2>/dev/null | grep -q ":${HELLO_NODE_PORT}"; then
      echo "[INFO] NodePort rule present for ${HELLO_NODE_PORT}"
      return 0
    fi
    if (( waited % 30 == 0 )); then echo "[DEBUG] NodePort rule missing (waited ${waited}s)"; fi
    sleep 5; waited=$((waited+5))
  done
  echo "[WARN] NodePort rule not detected after ${timeout}s"
  return 1
}

main() {
  echo "[INFO] Starting k3s installation"
  echo "[INFO] Node Type: $([ "${NODE_INDEX:-0}" = "0" ] && echo "Server" || echo "Agent")"
  systemctl disable --now ufw 2>/dev/null || true
  wait_for_system
  install_system_deps
  setup_swap
  install_docker
  install_k3s
  wait_for_core_components
  wait_for_traefik
  install_helm
  setup_helm_repos
  install_ingress
  install_cert_manager
  install_flux
  fetch_chart_source
  deploy_hello_world
  wait_for_hello_world_ingress || true
  wait_for_nodeport_rule || true
  install_monitoring
  expose_monitoring
  finalize_installation
}

trap 'echo "[ERROR] Installation failed at line $LINENO"' ERR
main "$@"
