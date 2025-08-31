#!/bin/bash -xe
exec > >(tee -a /var/log/cloud-init-output.log /var/log/user-data.log) 2>&1
set -euo pipefail

# Template variables substituted by Terraform templatefile():
NODE_INDEX="${NODE_INDEX}"
SERVER_IP="${SERVER_IP}"
K3S_TOKEN="${K3S_TOKEN}"

mkdir -p /tmp/user-data-test
echo "[USER-DATA-TEST] User-data script executed at $(date)" | tee /tmp/user-data-test/debug.log /var/log/cloud-init-output.log || true
touch /tmp/user-data-test/marker

echo "[INFO] user-data: starting installer (node_index=$NODE_INDEX)"

# Create installer script inline (more reliable than downloading)
cat > /tmp/k3s_install.sh << 'INSTALLER_EOF'
${installer_script}
INSTALLER_EOF

chmod +x /tmp/k3s_install.sh

# Export variables for the installer
export NODE_INDEX SERVER_IP K3S_TOKEN

# Run the installer
/tmp/k3s_install.sh

echo "[INFO] user-data complete"
