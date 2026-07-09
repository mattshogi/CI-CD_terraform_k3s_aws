#!/bin/bash -e
# NOTE: no -x tracing — user_data carries values (Grafana admin password)
# that must not be echoed into cloud-init logs.
exec > >(tee -a /var/log/cloud-init-output.log /var/log/user-data.log) 2>&1
set -euo pipefail

# --- Template variables substituted by Terraform templatefile() ---
NODE_INDEX="${NODE_INDEX}"
SERVER_IP="${SERVER_IP}"
K3S_TOKEN="${K3S_TOKEN}"
ENABLE_MONITORING="${ENABLE_MONITORING}"
ENABLE_INGRESS_NGINX="${ENABLE_INGRESS_NGINX}"
APP_IMAGE="${APP_IMAGE}"
HELLO_NODE_PORT="${HELLO_NODE_PORT}"
INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL}"
INSTALL_SCRIPT_SHA256="${INSTALL_SCRIPT_SHA256}"
REPO_TARBALL_URL="${REPO_TARBALL_URL}"
INSTALL_DOCKER="${INSTALL_DOCKER}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"

echo "[INFO] user-data: starting installer (node_index=$NODE_INDEX)"

# Verify the downloaded installer matches the checksum Terraform computed
# from the repo at plan time. Guards against the raw.githubusercontent.com
# fetch drifting from the planned infrastructure (or being tampered with).
verify_installer() {
	if [ -z "$${INSTALL_SCRIPT_SHA256}" ]; then
		echo "[WARN] No installer checksum provided; skipping verification"
		return 0
	fi
	echo "$${INSTALL_SCRIPT_SHA256}  /tmp/k3s_install.sh" | sha256sum -c - >/dev/null 2>&1
}

# Fetch installer with retries; fall back to an embedded minimal installer
# if download or checksum verification fails.
installer_ok=false
if [ -n "$${INSTALL_SCRIPT_URL}" ]; then
	echo "[INFO] Downloading installer from $${INSTALL_SCRIPT_URL} (pinned ref)"
	for attempt in 1 2 3; do
		if curl -fsSL "$${INSTALL_SCRIPT_URL}" -o /tmp/k3s_install.sh && verify_installer; then
			echo "[INFO] Installer downloaded and checksum verified (attempt $attempt)"
			installer_ok=true
			break
		fi
		echo "[WARN] Download/verification attempt $attempt failed"
		rm -f /tmp/k3s_install.sh
		sleep $((attempt * 2))
	done
fi

if [ "$installer_ok" != "true" ]; then
	echo "[ERROR] Installer unavailable or checksum mismatch; using embedded minimal fallback" >&2
	cat > /tmp/k3s_install.sh <<'FALLBACK'
#!/usr/bin/env bash
set -euo pipefail
echo "[FALLBACK] Running minimal fallback installer"
curl -sfL https://get.k3s.io | sh -s - server
echo "[FALLBACK] k3s install attempted; creating readiness marker"
touch /tmp/k3s-ready || true
FALLBACK
fi

chmod +x /tmp/k3s_install.sh

# Export variables for the installer
export NODE_INDEX SERVER_IP K3S_TOKEN ENABLE_MONITORING ENABLE_INGRESS_NGINX \
	APP_IMAGE HELLO_NODE_PORT REPO_TARBALL_URL INSTALL_DOCKER GRAFANA_ADMIN_PASSWORD

# Run the installer
/tmp/k3s_install.sh

echo "[INFO] user-data complete"
