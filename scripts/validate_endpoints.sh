#!/usr/bin/env bash
# Automated endpoint validation for k3s services

set -euo pipefail

SERVER_IP="$1"
RETRIES=10
SLEEP=30

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 <server_public_ip>"
  exit 1
fi

echo "[INFO] Validating service endpoints on $SERVER_IP"

# Test Hello World service
echo "[INFO] Testing Hello World service..."
for i in $(seq 1 $RETRIES); do
  echo "Attempt $i/$RETRIES: Checking Hello World..."
  if curl -fsSL --max-time 10 "http://$SERVER_IP/" | grep -q "Hello"; then
    echo "[SUCCESS] Hello World is reachable!"
    break
  elif [ $i -eq $RETRIES ]; then
    echo "[ERROR] Hello World not reachable after $RETRIES attempts"
    exit 1
  fi
  echo "Waiting ${SLEEP}s before retry..."
  sleep $SLEEP
done

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
