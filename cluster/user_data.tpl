#!/bin/bash -xe
exec > >(tee -a /var/log/cloud-init-output.log /var/log/user-data.log) 2>&1
set -euo pipefail

# Template variables substituted by Terraform templatefile():
NODE_INDEX="${NODE_INDEX}"
SERVER_IP="${SERVER_IP}"
K3S_TOKEN="${K3S_TOKEN}"
ENABLE_MONITORING="${ENABLE_MONITORING}"
ENABLE_INGRESS_NGINX="${ENABLE_INGRESS_NGINX}"
APP_IMAGE="${APP_IMAGE}"
HELLO_NODE_PORT="${HELLO_NODE_PORT}"
INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL}"
INSTALL_DOCKER="${INSTALL_DOCKER}"

mkdir -p /tmp/user-data-test
echo "[USER-DATA-TEST] User-data script executed at $(date)" | tee /tmp/user-data-test/debug.log /var/log/cloud-init-output.log || true
touch /tmp/user-data-test/marker

echo "[INFO] user-data: starting installer (node_index=$NODE_INDEX)"

# Fetch installer with retries; fallback to embedded minimal installer if download fails
if [ -n "$${INSTALL_SCRIPT_URL:-}" ]; then
	echo "[INFO] Attempting to download installer from $${INSTALL_SCRIPT_URL}"
	for attempt in 1 2 3; do
		if curl -fsSL "$${INSTALL_SCRIPT_URL}" -o /tmp/k3s_install.sh; then
			echo "[INFO] Installer downloaded successfully (attempt $attempt)"; break
		else
			echo "[WARN] Download attempt $attempt failed"
			sleep $((attempt*2))
		fi
	done
	if [ ! -s /tmp/k3s_install.sh ]; then
		echo "[ERROR] Failed to download installer after retries; using embedded minimal fallback" >&2
		cat > /tmp/k3s_install.sh <<'FALLBACK'
#!/usr/bin/env bash
set -euo pipefail
echo "[FALLBACK] Running minimal fallback installer"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -s - server
echo "[FALLBACK] k3s install attempted; creating readiness marker"
touch /tmp/k3s-ready || true
FALLBACK
	fi
else
	echo "[ERROR] INSTALL_SCRIPT_URL not provided; aborting (no fallback for explicit missing URL)" >&2
	exit 1
fi

chmod +x /tmp/k3s_install.sh || true

# Export variables for the installer
export NODE_INDEX SERVER_IP K3S_TOKEN ENABLE_MONITORING ENABLE_INGRESS_NGINX APP_IMAGE HELLO_NODE_PORT INSTALL_SCRIPT_URL INSTALL_DOCKER

# Run the installer
/tmp/k3s_install.sh

echo "[INFO] user-data complete"
