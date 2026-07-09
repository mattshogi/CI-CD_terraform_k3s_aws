# Remote state on S3 with Terraform-native lockfile-based locking (no
# DynamoDB table needed on Terraform >= 1.11).
#
# Partial configuration: bucket/key/region come from -backend-config so the
# same code serves local dev and per-run ephemeral CI state keys.
#
#   scripts/bootstrap_remote_state.sh        # one-time bucket creation
#   terraform -chdir=infra init -backend-config=backend.hcl
#
# CI passes an isolated key per run (ephemeral/<run_id>.tfstate) so a crashed
# job leaves recoverable state instead of orphaned, untracked resources.
#
# Validation-only contexts use `terraform init -backend=false`.
terraform {
  backend "s3" {}
}
