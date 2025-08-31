#!/usr/bin/env bash
# Automated endpoint validation for k3s services

set -euo pipefail

SERVER_IP="${1:-}"
HELLO_NODE_PORT="${HELLO_NODE_PORT:-30080}"
RETRIES=${RETRIES:-30}
SLEEP=${SLEEP:-10}

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 <server_public_ip>"
  exit 1
fi

echo "[INFO] Validating service endpoints on $SERVER_IP"

# Test Hello World service
echo "[INFO] Testing Hello World service (Ingress + NodePort fallback)..."
hello_ok=false
for i in $(seq 1 $RETRIES); do
  echo "Attempt $i/$RETRIES: Ingress /"
  if curl -fsSL --max-time 10 "http://$SERVER_IP/" | grep -qi "Hello"; then
    echo "[SUCCESS] Ingress root returned Hello"
    hello_ok=true; break
  fi
  echo "Attempt $i/$RETRIES: NodePort :$HELLO_NODE_PORT/"
  if curl -fsSL --max-time 10 "http://$SERVER_IP:$HELLO_NODE_PORT/" | grep -qi "Hello"; then
    echo "[SUCCESS] NodePort returned Hello"
    hello_ok=true; break
  fi
  if [ $i -lt $RETRIES ]; then
    echo "Waiting ${SLEEP}s before retry..."
    sleep $SLEEP
  fi
done
if [ "$hello_ok" != true ]; then
  echo "[ERROR] Hello World not reachable via Ingress or NodePort after $RETRIES attempts" >&2
  exit 1
fi

# Test Prometheus (optional)
echo "[INFO] Testing Prometheus..."
if curl -fsSL --max-time 10 "http://$SERVER_IP:9090/-/healthy" >/dev/null 2>&1; then
  echo "[SUCCESS] Prometheus is reachable!"
else
  echo "[WARNING] Prometheus not reachable (may still be starting)"
fi

# Test Grafana (optional)
echo "[INFO] Testing Grafana..."
if curl -fsSL --max-time 10 "http://$SERVER_IP:3000/api/health" >/dev/null 2>&1; then
  echo "[SUCCESS] Grafana is reachable!"
else
  echo "[WARNING] Grafana not reachable (may still be starting)"
fi

echo "[INFO] Endpoint validation completed"
