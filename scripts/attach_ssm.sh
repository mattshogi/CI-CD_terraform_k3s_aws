#!/usr/bin/env bash
set -euo pipefail
cwd=$(cd "$(dirname "$0")/.." && pwd)
ASSUME_FILE="$cwd/assume-ssm.json"
ROLE="k3s-ssm-role-$(date +%s)"
INSTANCE_ID="i-03fe5e976846ba0be"

echo "Using assume file: $ASSUME_FILE"

# Create role (ignore if exists)
aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://"$ASSUME_FILE" --description "Role to allow SSM on k3s instance" >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" --iam-instance-profile Name="$ROLE" >/dev/null 2>&1 || true

echo "Association attempted. Polling for SSM registration (120s)..."
for i in $(seq 1 24); do
  sleep 5
  echo -n "."
  count=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList | length')
  if [ "$count" -gt 0 ]; then
    echo; echo "SSM registered"
    aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList[0]'
    exit 0
  fi
done

echo; echo "SSM did not register within timeout"
aws ssm describe-instance-information --output json | jq '.' || true
exit 0
