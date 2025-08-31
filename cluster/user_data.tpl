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

# Create installer script inline (more reliable than downloading)
if [ -n "$${INSTALL_SCRIPT_URL:-}" ]; then
	echo "[INFO] Downloading installer from $${INSTALL_SCRIPT_URL}"
	curl -fsSL "$${INSTALL_SCRIPT_URL}" -o /tmp/k3s_install.sh
else
	echo "[ERROR] INSTALL_SCRIPT_URL not provided" >&2
	exit 1
fi

chmod +x /tmp/k3s_install.sh

# Export variables for the installer
export NODE_INDEX SERVER_IP K3S_TOKEN ENABLE_MONITORING ENABLE_INGRESS_NGINX APP_IMAGE HELLO_NODE_PORT INSTALL_SCRIPT_URL INSTALL_DOCKER

# Run the installer
/tmp/k3s_install.sh

echo "[INFO] user-data complete"
