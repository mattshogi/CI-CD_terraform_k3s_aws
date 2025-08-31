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
