#!/usr/bin/env bash
set -euo pipefail
INSTANCE_ID="i-03fe5e976846ba0be"
ROLE_PREFIX="k3s-ssm-role"
ASSUME_FILE="$(pwd)/assume-ssm.json"

# Find existing role
ROLE_NAME=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${ROLE_PREFIX}')].RoleName | [0]" --output text)
if [ "$ROLE_NAME" = "None" ] || [ -z "$ROLE_NAME" ]; then
  ROLE_NAME="${ROLE_PREFIX}-$(date +%s)"
  echo "Creating role $ROLE_NAME"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://"$ASSUME_FILE" --description "Role to allow SSM on k3s instance"
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
else
  echo "Found existing role: $ROLE_NAME"
fi

# Ensure instance profile exists
PROFILE_NAME="$ROLE_NAME"
PROFILE_EXISTS=$(aws iam list-instance-profiles --query "InstanceProfiles[?InstanceProfileName=='${PROFILE_NAME}'].InstanceProfileName | [0]" --output text)
if [ "$PROFILE_EXISTS" = "None" ] || [ -z "$PROFILE_EXISTS" ]; then
  echo "Creating instance profile $PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
else
  echo "Instance profile $PROFILE_NAME exists"
fi

# Add role to instance profile (if not present)
HAS_ROLE=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query "InstanceProfile.Roles[?RoleName=='${ROLE_NAME}'] | [0]" --output text || true)
if [ "$HAS_ROLE" = "None" ] || [ -z "$HAS_ROLE" ]; then
  echo "Adding role $ROLE_NAME to profile $PROFILE_NAME"
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
else
  echo "Role already present in instance profile"
fi

# Get instance-profile ARN
PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query 'InstanceProfile.Arn' --output text)
echo "Instance profile ARN: $PROFILE_ARN"

# Associate profile with instance using ARN
echo "Associating instance profile ARN with instance"
ASSOC=$(aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" --iam-instance-profile Arn="$PROFILE_ARN" --output json 2>/dev/null || true)
if [ -n "$ASSOC" ]; then
  echo "Associate response:"; echo "$ASSOC" | jq .
fi

# Show current associations
echo "Current IAM instance profile associations for the instance:"
aws ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values="$INSTANCE_ID" --output json | jq .IamInstanceProfileAssociations || true

echo "Instance attribute iam instance profile:" 
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --output json | jq .Reservations[0].Instances[0].IamInstanceProfile || true

# Poll SSM for registration
echo "Polling SSM for 120s..."
for i in $(seq 1 24); do
  sleep 5
  echo -n "."
  COUNT=$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq '.InstanceInformationList | length')
  if [ "$COUNT" -gt 0 ]; then
    echo; echo "SSM registered"; aws ssm describe-instance-information --filters Key=InstanceIds,Values="$INSTANCE_ID" --output json | jq .InstanceInformationList[0]; exit 0
  fi
done

echo; echo "SSM did not register"
aws ssm describe-instance-information --output json | jq . || true
exit 0
