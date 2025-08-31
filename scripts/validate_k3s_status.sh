#!/usr/bin/env bash
# Automated k3s cluster health check

set -euo pipefail

SERVER_IP="$1"
RETRIES=20
SLEEP=15
SSH_KEY="${SSH_KEY_PATH:-~/.ssh/id_rsa}"

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 <server_public_ip>"
  exit 1
fi

echo "[INFO] Checking k3s cluster health on $SERVER_IP"

for i in $(seq 1 $RETRIES); do
  echo "Attempt $i/$RETRIES: Checking cluster status..."
  
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY" ubuntu@"$SERVER_IP" '
    # Check if k3s is running
    if ! sudo systemctl is-active --quiet k3s; then
      echo "k3s service not active"
      exit 1
    fi
    
    # Check cluster nodes
    if ! sudo k3s kubectl get nodes --no-headers | grep -q Ready; then
      echo "No ready nodes found"
      exit 1
    fi
    
    # Check critical pods
    if ! sudo k3s kubectl get pods -A --no-headers | grep -E "(kube-system|ingress-nginx)" | grep -v -E "(Completed|Running)"; then
      echo "Critical pods not ready"
      exit 1
    fi
    
    echo "Cluster is healthy"
    sudo k3s kubectl get nodes
    sudo k3s kubectl get pods -A
  '; then
    echo "[SUCCESS] Cluster is healthy!"
    exit 0
  fi
  
  echo "Cluster not ready yet, waiting ${SLEEP}s..."
  sleep $SLEEP
done

echo "[ERROR] Cluster did not become healthy within expected time"
exit 1
for i in $(seq 1 $RETRIES); do
  echo "[INFO] Attempt $i/$RETRIES: Checking k3s pod and service status..."

  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/.ssh/id_k3s_aws ubuntu@${SERVER_IP} bash -s <<'REMOTE'
set -e
KUBE="/etc/rancher/k3s/k3s.yaml"
echo "[REMOTE] Using kubeconfig: $KUBE"

# List pods/services/ingress for debugging
echo "[REMOTE] kubectl get pods -A -o wide"
sudo env KUBECONFIG=$KUBE kubectl get pods -A -o wide || true

echo "[REMOTE] kubectl get svc -A -o wide"
sudo env KUBECONFIG=$KUBE kubectl get svc -A -o wide || true

echo "[REMOTE] kubectl -n ingress-nginx get pods -o wide"
sudo env KUBECONFIG=$KUBE kubectl -n ingress-nginx get pods -o wide || true

echo "[REMOTE] kubectl get ingress -A"
sudo env KUBECONFIG=$KUBE kubectl get ingress -A || true

# Determine if any pod is not ready. We look at the READY column (e.g. 1/1)
not_ready=$(sudo env KUBECONFIG=$KUBE kubectl get pods -A --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1] != a[2]) print $0}' | wc -l)

if [ "$not_ready" -eq 0 ]; then
  echo "[REMOTE] All pods show Ready (0 not-ready)."
  exit 0
else
  echo "[REMOTE] Found $not_ready not-ready pod(s)."
  exit 2
fi
REMOTE

  rc=$?
  if [ $rc -eq 0 ]; then
    echo "[INFO] Cluster appears healthy (pods Ready)."
    break
  else
    echo "[WARN] Cluster not ready yet (remote rc=$rc). Sleeping $SLEEP seconds..."
    sleep $SLEEP
  fi
done

if [ $i -eq $RETRIES ]; then
  echo "[ERROR] Reached maximum retries ($RETRIES) and cluster is not healthy."
  exit 2
fi
