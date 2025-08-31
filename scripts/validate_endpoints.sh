#!/usr/bin/env bash
# Automated endpoint validation for k3s services with richer diagnostics

set -euo pipefail

SERVER_IP="${1:-}"
HELLO_NODE_PORT="${HELLO_NODE_PORT:-30080}"
RETRIES=${2:-${RETRIES:-30}}   # positional arg overrides env/default
SLEEP=${3:-${SLEEP:-10}}       # positional arg overrides env/default

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 <server_public_ip> [retries] [sleep_seconds]" >&2
  exit 1
fi

echo "[INFO] Validating service endpoints on $SERVER_IP (retries=$RETRIES sleep=${SLEEP}s nodePort=${HELLO_NODE_PORT})"

hello_ok=false
ingress_first_seen=""
nodeport_first_seen=""

for i in $(seq 1 $RETRIES); do
  printf "[ATTEMPT %d/%d] Ingress / ... " "$i" "$RETRIES"
  set +e
  ingress_body=$(curl -sS --max-time 8 -w "HTTPSTATUS:%{http_code}" "http://$SERVER_IP/" || true)
  ingress_code=${ingress_body##*HTTPSTATUS:}
  ingress_content=${ingress_body%HTTPSTATUS:*}
  set -e
  if printf '%s' "$ingress_content" | grep -qi "Hello"; then
    echo "FOUND (code=$ingress_code)"
    hello_ok=true
    [ -z "$ingress_first_seen" ] && ingress_first_seen="$i"
    break
  else
    echo "miss (code=${ingress_code:-na})"
  fi

  printf "[ATTEMPT %d/%d] NodePort / (:%s) ... " "$i" "$RETRIES" "$HELLO_NODE_PORT"
  set +e
  node_body=$(curl -sS --max-time 8 -w "HTTPSTATUS:%{http_code}" "http://$SERVER_IP:$HELLO_NODE_PORT/" || true)
  node_code=${node_body##*HTTPSTATUS:}
  node_content=${node_body%HTTPSTATUS:*}
  set -e
  if printf '%s' "$node_content" | grep -qi "Hello"; then
    echo "FOUND (code=$node_code)"
    hello_ok=true
    [ -z "$nodeport_first_seen" ] && nodeport_first_seen="$i"
    break
  else
    echo "miss (code=${node_code:-na})"
  fi

  if [ $i -lt $RETRIES ]; then
    echo "[INFO] Waiting ${SLEEP}s before next attempt..."
    sleep "$SLEEP"
  fi
done

if [ "$hello_ok" != true ]; then
  echo "[ERROR] Hello World not reachable via Ingress or NodePort after $RETRIES attempts" >&2
  echo "[HINT] Check: k3s svc/ingress readiness, Traefik pods, security group (80 & NodePort range), and diagnostics artifact." >&2
  exit 1
fi

echo "[INFO] Hello World reachable (ingress_first_seen=${ingress_first_seen:-none} nodeport_first_seen=${nodeport_first_seen:-none})"

# Optional monitoring endpoints
echo "[INFO] Testing Prometheus (NodePort 30900 or cluster default 9090)..."
if curl -fsSL --max-time 5 "http://$SERVER_IP:9090/-/healthy" >/dev/null 2>&1 || curl -fsSL --max-time 5 "http://$SERVER_IP:30900/-/healthy" >/dev/null 2>&1; then
  echo "[SUCCESS] Prometheus is reachable"
else
  echo "[WARN] Prometheus not reachable (may be disabled or still starting)"
fi

echo "[INFO] Testing Grafana (NodePort 30030 or default 3000)..."
if curl -fsSL --max-time 5 "http://$SERVER_IP:3000/api/health" >/dev/null 2>&1 || curl -fsSL --max-time 5 "http://$SERVER_IP:30030/api/health" >/dev/null 2>&1; then
  echo "[SUCCESS] Grafana is reachable"
else
  echo "[WARN] Grafana not reachable (may be disabled or still starting)"
fi

echo "[INFO] Endpoint validation completed"
