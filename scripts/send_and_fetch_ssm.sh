#!/usr/bin/env bash
set -euo pipefail
INSTANCE_ID="i-03fe5e976846ba0be"
PARAM_FILE="/tmp/ssm_cmd_params.json"
if [ ! -f "$PARAM_FILE" ]; then
  echo "Missing $PARAM_FILE"
  exit 1
fi

CMD_JSON=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name "AWS-RunShellScript" --parameters file://"$PARAM_FILE" --comment "diagnostics" --output json)
CMD_ID=$(echo "$CMD_JSON" | jq -r .Command.CommandId)
echo "Sent command: $CMD_ID"

for i in $(seq 1 60); do
  sleep 3
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --details --output json | jq -r '.CommandInvocations[0].Status // ""' || true)
  echo "status: $STATUS"
  if [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ] || [ "$STATUS" = "TimedOut" ] || [ "$STATUS" = "Cancelled" ] || [ "$STATUS" = "Completed" ]; then
    break
  fi
done

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --output json | jq . || true
