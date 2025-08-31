#!/usr/bin/env bash
set -euo pipefail
INSTANCE_ID="i-03fe5e976846ba0be"

echo "--- iam instance profile associations for instance ---"
aws ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values="$INSTANCE_ID" --output json | jq .IamInstanceProfileAssociations || true

echo "--- instance attribute iam instance profile ---"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --output json | jq .Reservations[0].Instances[0].IamInstanceProfile || true

echo "--- rebooting instance $INSTANCE_ID ---"
aws ec2 reboot-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true

echo "reboot requested. sleeping 30s"
sleep 30

echo "Polling SSM for 180s..."
for i in $(seq 1 36); do
  sleep 5
  echo -n "."
  count=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList | length')
  if [ "$count" -gt 0 ]; then
    echo; echo "SSM registered"; aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList[0]'; exit 0
  fi
done

echo

echo "SSM did not register after reboot"
aws ssm describe-instance-information --output json | jq . || true
exit 0
