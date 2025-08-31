#!/usr/bin/env bash
set -euo pipefail
INSTANCE_ID="i-03fe5e976846ba0be"

echo "Waiting for IAM instance-profile association (60s max)..."
for i in $(seq 1 12); do
  STATE=$(aws ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values="$INSTANCE_ID" --output json | jq -r '.IamInstanceProfileAssociations[0].State // ""' || true)
  echo "association state: '$STATE'"
  if [ "$STATE" = "associated" ]; then
    echo "Instance profile associated"
    break
  fi
  sleep 5
done

echo "Polling SSM for registration (180s max)..."
for i in $(seq 1 36); do
  COUNT=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList | length' || true)
  echo "ssm count: $COUNT"
  if [ "$COUNT" -gt 0 ]; then
    echo "SSM registered"
    aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq .InstanceInformationList[0]
    break
  fi
  sleep 5
done

COUNT=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList | length' || true)
if [ "$COUNT" -eq 0 ]; then
  echo "Instance not present in SSM after timeout"
  exit 2
fi

# Prepare commands file
CMDFILE="/tmp/ssm_diag_cmd.json"
cat > "$CMDFILE" <<'JSON'
{
  "commands": [
    "echo '=== sshd status ==='",
    "sudo systemctl status ssh || sudo systemctl status sshd || true",
    "echo '=== listening sockets ==='",
    "sudo ss -ltnp || sudo netstat -ltnp || true",
    "echo '=== firewall rules ==='",
    "sudo ufw status || sudo iptables -S || sudo iptables -L -n || true",
    "echo '=== ssh logs (journal) ==='",
    "sudo journalctl -u ssh -n 200 --no-pager || sudo journalctl -u sshd -n 200 --no-pager || true",
    "echo '=== tail cloud-init-output.log ==='",
    "sudo tail -n 500 /var/log/cloud-init-output.log || true"
  ]
}
JSON

echo "Sending RunCommand via SSM (commands file: $CMDFILE)"
CMD_JSON=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name "AWS-RunShellScript" --parameters file://"$CMDFILE" --comment "ssm diagnostics" --output json)
CMD_ID=$(echo "$CMD_JSON" | jq -r '.Command.CommandId')

echo "Command sent: $CMD_ID"

# Poll for command completion
for i in $(seq 1 40); do
  sleep 3
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --details --output json | jq -r '.CommandInvocations[0].Status // ""' || true)
  echo "command status: $STATUS"
  if [[ "$STATUS" =~ "Success" || "$STATUS" =~ "Failed" || "$STATUS" =~ "TimedOut" || "$STATUS" =~ "Cancelled" || "$STATUS" =~ "Completed" ]]; then
    break
  fi
done

echo "Fetching command invocation output..."
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --output json | jq . || true

exit 0
