#!/usr/bin/env bash
# Tear down an ephemeral environment by run id, against its per-run state key.
#
# Shared by .github/workflows/deploy-ephemeral.yml and platformctl so teardown
# is one code path. The caller's job-level TF_VAR_* environment (ha_mode etc.)
# is inherited so the destroy plan matches what was applied.
set -euo pipefail

: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
: "${RUN_ID:?RUN_ID is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[destroy_env] init (state key ephemeral/${RUN_ID}.tfstate)"
terraform -chdir="${ROOT}/infra" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=ephemeral/${RUN_ID}.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

echo "[destroy_env] destroy"
terraform -chdir="${ROOT}/infra" destroy -auto-approve -input=false
