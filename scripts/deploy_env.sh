#!/usr/bin/env bash
# Provision (or plan) an ephemeral environment against per-run remote state.
#
# This is the single source of truth for "deploy an env". Both
# .github/workflows/deploy-ephemeral.yml and platformctl (core/exec.go) call
# it, so the agent ops layer and the CI pipeline drive the exact same commands
# instead of two drifting copies of the deploy logic.
#
# Config via environment:
#   TF_STATE_BUCKET   (required) S3 bucket holding remote state
#   RUN_ID            (required) per-run state key suffix -> ephemeral/<RUN_ID>.tfstate
#   AWS_REGION        (default us-east-1)
#   MODE              plan|apply (default plan; dry-run is the safe default)
#   TF_VAR_*          passed through to Terraform by the caller
# Optional resolution helpers (used only when the matching TF_VAR is unset):
#   ADMIN_CIDR        overrides admin_cidr; else the caller's public IP as /32
#   IMAGE_REF         overrides app_image; else ghcr .../hello-world:sha-<GITHUB_SHA>
#   GITHUB_SHA        commit used for the default image tag
#
# On apply it prints terraform outputs as KEY=VALUE lines on stdout (and
# appends them to $GITHUB_OUTPUT when that is set) so callers can parse them.
set -euo pipefail

: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
: "${RUN_ID:?RUN_ID is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MODE="${MODE:-plan}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${ROOT}/terraform-apply.log"

# Operator ports (kube API, NodePorts) open only to this caller's IP.
if [ -z "${TF_VAR_admin_cidr:-}" ]; then
  if [ -n "${ADMIN_CIDR:-}" ]; then
    export TF_VAR_admin_cidr="${ADMIN_CIDR}"
  else
    # Split assignment so a failed lookup is not masked by export's exit code.
    my_ip="$(curl -fsS https://checkip.amazonaws.com)"
    export TF_VAR_admin_cidr="${my_ip}/32"
  fi
fi

# Deploy the image CI built for this commit, unless one is provided.
if [ -z "${TF_VAR_app_image:-}" ]; then
  if [ -n "${IMAGE_REF:-}" ]; then
    export TF_VAR_app_image="${IMAGE_REF}"
  elif [ -n "${GITHUB_SHA:-}" ]; then
    export TF_VAR_app_image="ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world:sha-${GITHUB_SHA}"
  fi
  # else Terraform's own default (…:main) applies
fi

echo "[deploy_env] init (state key ephemeral/${RUN_ID}.tfstate, mode ${MODE})"
terraform -chdir="${ROOT}/infra" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=ephemeral/${RUN_ID}.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

if [ "${MODE}" = "plan" ]; then
  echo "[deploy_env] plan (dry-run; nothing is created)"
  terraform -chdir="${ROOT}/infra" plan -input=false
  exit 0
fi

echo "[deploy_env] apply"
set -o pipefail
if ! terraform -chdir="${ROOT}/infra" apply -auto-approve -input=false 2>&1 | tee "${LOG}"; then
  # Retry once on known-transient AWS errors (throttling, IAM propagation, etc).
  if grep -qiE 'Throttling|RequestLimitExceeded|NoSuchEntity|InvalidIAMInstanceProfile|ServiceUnavailable|InternalError|DependencyViolation' "${LOG}"; then
    echo "[deploy_env] transient failure detected; retrying in 30s" >&2
    sleep 30
    terraform -chdir="${ROOT}/infra" apply -auto-approve -input=false 2>&1 | tee -a "${LOG}"
  else
    echo "[deploy_env] apply failed" >&2
    exit 1
  fi
fi

emit() {
  echo "${1}=${2}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "${1}=${2}" >> "${GITHUB_OUTPUT}"; fi
}

tf() { terraform -chdir="${ROOT}/infra" "$@"; }
server_ip="$(tf output -raw server_public_ip 2>/dev/null || true)"
instance_id="$(tf output -raw server_instance_id 2>/dev/null || true)"
endpoint_host="$(tf output -raw endpoint_host 2>/dev/null || true)"
[ -n "${endpoint_host}" ] || endpoint_host="${server_ip}"
instance_ids="$(tf output -json server_instance_ids 2>/dev/null || echo '[]')"

emit server_ip "${server_ip}"
emit instance_id "${instance_id}"
emit endpoint_host "${endpoint_host}"
emit instance_ids "${instance_ids}"
emit app_image "${TF_VAR_app_image:-ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world:main}"
