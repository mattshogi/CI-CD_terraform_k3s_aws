#!/usr/bin/env bash
# k3s cluster health check over SSM (no SSH / no inbound ports required).
#
# Usage: validate_k3s_status.sh [instance-id]
#   Defaults to the server_instance_id Terraform output.
set -euo pipefail

INSTANCE_ID="${1:-}"
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(terraform -chdir="$(dirname "$0")/../infra" output -raw server_instance_id 2>/dev/null || true)
fi
if [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <instance-id>  (or run from a repo with terraform state)" >&2
  exit 1
fi

RETRIES=${RETRIES:-20}
SLEEP=${SLEEP:-15}

echo "[INFO] Checking k3s health on $INSTANCE_ID via SSM"

check_cmd='set -e
systemctl is-active --quiet k3s || { echo "k3s service not active"; exit 1; }
k3s kubectl get nodes --no-headers | grep -q " Ready" || { echo "no Ready nodes"; exit 1; }
not_running=$(k3s kubectl get pods -n kube-system --no-headers | grep -cvE "(Running|Completed)" || true)
[ "$not_running" -eq 0 ] || { echo "$not_running kube-system pods not Running"; exit 1; }
echo "cluster healthy"
k3s kubectl get nodes
k3s kubectl get pods -A'

for i in $(seq 1 "$RETRIES"); do
  echo "[ATTEMPT $i/$RETRIES]"
  CID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters commands="$check_cmd" \
    --query 'Command.CommandId' --output text 2>/dev/null || true)

  if [ -n "$CID" ]; then
    sleep 8
    STATUS=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    if [ "$STATUS" = "Success" ]; then
      aws ssm get-command-invocation --command-id "$CID" --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' --output text
      echo "[SUCCESS] Cluster is healthy"
      exit 0
    fi
    echo "[INFO] Check status: $STATUS"
  else
    echo "[INFO] Instance not yet SSM-managed (agent still registering?)"
  fi

  [ "$i" -lt "$RETRIES" ] && sleep "$SLEEP"
done

echo "[ERROR] Cluster did not become healthy within $((RETRIES * SLEEP))s" >&2
exit 1
