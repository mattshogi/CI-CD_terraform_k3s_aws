#!/usr/bin/env bash
# Automated endpoint validation for k3s services with richer diagnostics

set -euo pipefail

SERVER="${1:-}"                # public IP (single-node) or NLB hostname (HA)
HELLO_NODE_PORT="${HELLO_NODE_PORT:-30080}"
RETRIES=${2:-${RETRIES:-30}}   # positional arg overrides env/default
SLEEP=${3:-${SLEEP:-10}}       # positional arg overrides env/default

if [ -z "$SERVER" ]; then
  echo "Usage: $0 <server_public_ip|host> [retries] [sleep_seconds]" >&2
  exit 1
fi

# Argument may be an IPv4 address (single-node: <ip>.sslip.io gives TLS a name)
# or a hostname such as the HA NLB DNS name (used directly, no sslip.io suffix).
if printf '%s' "$SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  TLS_HOST="${SERVER}.sslip.io"
else
  TLS_HOST="${SERVER}"
fi

echo "[INFO] Validating service endpoints on $SERVER (tls_host=$TLS_HOST retries=$RETRIES sleep=${SLEEP}s nodePort=${HELLO_NODE_PORT})"

hello_ok=false
ingress_first_seen=""
nodeport_first_seen=""

for i in $(seq 1 $RETRIES); do
  printf "[ATTEMPT %d/%d] Ingress / ... " "$i" "$RETRIES"
  set +e
  ingress_body=$(curl -sS --max-time 8 -w "HTTPSTATUS:%{http_code}" "http://$SERVER/" || true)
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
  node_body=$(curl -sS --max-time 8 -w "HTTPSTATUS:%{http_code}" "http://$SERVER:$HELLO_NODE_PORT/" || true)
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

# HTTPS via cert-manager (self-signed issuer → -k). For an IP arg, sslip.io
# wildcard DNS resolves <ip>.sslip.io to the instance so SNI matches the issued
# cert; for a hostname arg (HA NLB DNS) the name is used directly (TLS_HOST set
# at the top). Retried: certificate issuance can lag first HTTP availability.
TLS_RETRIES=${TLS_RETRIES:-12}
echo "[INFO] Testing HTTPS (https://${TLS_HOST}/, up to ${TLS_RETRIES} attempts)..."
https_ok=false
for i in $(seq 1 "$TLS_RETRIES"); do
  if curl -sk --max-time 8 "https://${TLS_HOST}/" | grep -qi "Hello"; then
    https_ok=true
    break
  fi
  [ "$i" -lt "$TLS_RETRIES" ] && sleep 10
done
if [ "$https_ok" = true ]; then
  issuer=$(echo | openssl s_client -connect "${TLS_HOST}:443" -servername "${TLS_HOST}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "issuer=<unreadable>")
  echo "[SUCCESS] HTTPS serving after $i attempt(s) (${issuer})"
else
  echo "[WARN] HTTPS not reachable (TLS disabled, cert still provisioning, or port 443 closed)"
fi

# Optional monitoring endpoints — NodePorts are only open to admin_cidr, so
# these succeed only when run from an allowed IP (e.g. the CI runner that
# deployed with its own IP as admin_cidr).
echo "[INFO] Testing Prometheus (NodePort 30900)..."
if curl -fsSL --max-time 5 "http://$SERVER:30900/-/healthy" >/dev/null 2>&1; then
  echo "[SUCCESS] Prometheus is reachable"
else
  echo "[WARN] Prometheus not reachable (disabled, still starting, or this IP is not in admin_cidr)"
fi

echo "[INFO] Testing Grafana (NodePort 30030)..."
if curl -fsSL --max-time 5 "http://$SERVER:30030/api/health" >/dev/null 2>&1; then
  echo "[SUCCESS] Grafana is reachable"
else
  echo "[WARN] Grafana not reachable (disabled, still starting, or this IP is not in admin_cidr)"
fi

echo "[INFO] Endpoint validation completed"
