# Design Decisions

Short decision records for the non-obvious choices in this repo — what was
chosen, what was rejected, and why. Ordered roughly by how often the
question comes up.

## 1. k3s on EC2 instead of EKS

**Choice:** single-binary k3s on one EC2 instance.
**Rejected:** EKS, self-managed kubeadm.

EKS costs ~$73/month for the control plane alone before any nodes, and takes
15–20 minutes to provision — hostile to the ephemeral create/validate/destroy
loop this repo is built around. k3s boots to a Ready node in under two
minutes on a t3.small and exercises the same Kubernetes API surface
(Deployments, Services, Ingress, Helm). The trade-off is no managed control
plane, no HA, and no IAM-integrated RBAC — acceptable for a demo whose
clusters live for minutes. The Terraform module boundary (`modules/k3s-node`)
is where an EKS module would slot in if this grew up.

## 2. Ephemeral environments instead of a persistent cluster

**Choice:** every deploy provisions from nothing, validates over HTTP, and
destroys itself; state is kept per run.
**Rejected:** long-lived staging environment updated in place.

A persistent environment drifts, costs money while idle, and hides
bootstrap-order bugs (the kind that only appear on first boot). Ephemeral
runs prove the entire path — IaC, image, bootstrap, DNS-free endpoint
validation — on every dispatch. The cost is longer feedback (~8–10 min) and
having to solve state durability (see #3), which a persistent environment
gets for free.

## 3. Remote state with per-run keys, S3-native locking

**Choice:** S3 backend, partial configuration, `ephemeral/<run_id>.tfstate`
per CI run, `use_lockfile` (Terraform ≥ 1.11) instead of DynamoDB.
**Rejected:** local state in the runner workspace; a single shared state key;
DynamoDB lock table.

Local state made destroy-after-failure impossible: if the runner died between
apply and destroy, resources were orphaned with nothing tracking them.
Per-run keys give each ephemeral environment isolated, recoverable state —
concurrent runs can't fight over a lock, and a crashed run's state is right
there to destroy from. S3-native lockfiles remove the DynamoDB table that
existed only for locking. Partial backend config keeps bucket names out of
version control.

## 4. SSM Session Manager instead of SSH

**Choice:** IAM-role-based SSM for shell access and diagnostics; SSH off by
default (requires explicitly setting both `admin_cidr` and a key pair).
**Rejected:** SSH open to 0.0.0.0/0 (the original posture).

SSM needs zero inbound ports, is audited in CloudTrail, and works identically
from CI (send-command diagnostics on validation failure) and from an operator
laptop (`aws ssm start-session`). Port 22 open to the world on a public IP
collects brute-force noise within minutes. The general rule applied here:
every non-public port is closed unless an operator explicitly opens it to
their own CIDR.

## 5. GitHub OIDC instead of stored AWS keys

**Choice:** `infra/bootstrap/github-oidc` creates an identity provider and a
role whose trust policy is scoped to this repository; workflows get 1-hour
credentials via `id-token: write`.
**Rejected:** long-lived IAM user keys in repository secrets (kept only as a
fallback path).

Stored keys don't expire, leak into forks/logs, and grant whatever the IAM
user has, forever. The OIDC role's permission policy is scoped to what the
ephemeral stack manages (k3s-\* IAM resources, PassRole conditioned on
ec2.amazonaws.com, the state bucket) — and the trust policy's `sub` condition
can pin deploys to a branch or environment.

## 6. The Helm chart is the only deployment definition

**Choice:** one chart, installed by the bootstrap from the repo tarball at
the deployed commit's SHA; CI lints and renders the same chart.
**Rejected:** the previous state — three divergent definitions (a chart that
was linted but never installed, a kubectl heredoc that actually deployed, and
an orphaned static manifest).

Divergent definitions rot independently; the heredoc had probes the chart
lacked, the chart had an image the heredoc didn't use. One artifact, one
definition: CI validates exactly what production applies. Values overrides
handle the two variants (CI-built Go image vs. public fallback image).

## 7. Bootstrap pinned by ref + checksum

**Choice:** the instance downloads `k3s_install.sh` and the chart tarball at
the exact git SHA being deployed, and verifies the installer against a
SHA-256 computed by Terraform at plan time.
**Rejected:** fetching from the `main` branch at boot (original behavior).

Fetching `main` at boot meant any push changed what already-planned
infrastructure would do — an unversioned, unauditable deploy path. Pinning
makes instance bootstrap reproducible; the checksum catches drift and
tampering. The alternative — baking an AMI with Packer — is more robust but
slower to iterate and heavier than a demo warrants (noted as future work).

## 8. Deploy by immutable per-commit tag

**Choice:** CI tags images `sha-<full-commit-sha>`; the deploy workflow
passes that exact tag to Terraform → Helm.
**Rejected:** deploying `latest` (or, as originally: building an image and
deploying a completely different public one).

`latest` is a moving target: rollbacks are guesswork and two deploys of the
same config can run different code. A commit-addressed tag makes the running
container traceable to source, and rollback = redeploy the previous SHA.

## 9. Distroless, non-root runtime image

**Choice:** multi-stage build → `gcr.io/distroless/static:nonroot`; the chart
enforces runAsNonRoot, read-only rootfs, no capabilities, RuntimeDefault
seccomp.
**Rejected:** Alpine runtime image running as root.

A static Go binary needs no libc, shell, or package manager at runtime;
removing them removes both CVE surface (nothing for Trivy to flag) and
post-exploitation tooling. The pod securityContext mirrors the image's uid
so the two can't drift apart silently.

## 10. Single node, agents deferred

**Choice:** one server node; the old `infra/agents` and `infra/server`
directories were deleted rather than fixed.
**Rejected:** keeping half-wired multi-node code "for show".

The agents module could never plan (it passed 3 of 12 required template
variables) and the server directory was a drifted copy-paste fork with a
hardcoded AMI. Broken scaffolding costs more credibility than a smaller,
working scope. The path back to multi-node is explicit: instantiate
`modules/k3s-node` again with `NODE_INDEX=1`, the server IP, and the join
token (via SSM Parameter Store), plus a load balancer in front — the module
boundaries were drawn to make that additive, not a rewrite.

## 11. TLS: self-signed ClusterIssuer + sslip.io, not Let's Encrypt

**Choice:** cert-manager with a self-signed ClusterIssuer, certificates for
`<public-ip>.sslip.io` (wildcard DNS that resolves to the embedded IP).
**Rejected:** Let's Encrypt; skipping TLS entirely.

Ephemeral environments get a fresh public IP every run, so there's no stable
DNS name for ACME to validate — and LE rate-limits per registered domain,
which shared wildcard-DNS domains like sslip.io burn through. The self-signed
issuer exercises the entire cert-manager machinery (issuer → certificate →
secret → SNI-matched serving via Traefik) with zero external dependencies;
swapping to production TLS is one ClusterIssuer plus one annotation once a
real domain exists. Browsers warn — accepted and documented.

## 12. GitOps as a mode, not a mandate

**Choice:** Flux (source + helm controllers only) behind `enable_gitops`,
default off; a full-SHA ref pins the GitRepository to a commit, a branch ref
reconciles continuously.
**Rejected:** Argo CD; making GitOps the only deploy path.

Argo CD's UI is nice but its footprint doesn't fit a t3.small already
running a monitoring stack; Flux's two needed controllers do. GitOps stays a
flag because the two modes prove different things: push-time Helm proves the
artifact pipeline; Flux proves drift-corrected reconciliation. The SHA-vs-
branch ref split resolves the tension between GitOps ("track a branch") and
ephemeral reproducibility ("pin everything") instead of pretending it doesn't
exist. Flux failure degrades gracefully to the direct Helm path.

## 13. Baked AMIs as an opt-in accelerator

**Choice:** Packer bakes deps + Helm + the k3s binary + airgap images, but
NOT an enabled k3s service; boot-time installer detects the baked binary
(`INSTALL_K3S_SKIP_DOWNLOAD`) and only renders the service unit.
**Rejected:** fully-configured golden image; making the baked AMI the default.

Node identity and runtime flags are per-instance concerns — baking a started
k3s would freeze them and leak bake-time state into every instance. Skipping
just the downloads keeps one bootstrap code path for both AMI types while
removing its slowest steps. Opt-in (`use_baked_ami`) because stock-Ubuntu
boots must keep working: the baked image is an optimization, not a
dependency, and bakes only happen when someone runs the workflow.

## Known limitations / future work

- Let's Encrypt issuer + real domain for browser-trusted TLS (see #11).
- Multi-node: instantiate `modules/k3s-node` for agents with the join token
  via SSM Parameter Store (see #10).
- Scheduled AMI re-bakes (patch currency) and pruning of old `k3s-node-*`
  AMIs/snapshots.
- S3 lifecycle rule to expire orphaned `ephemeral/*` state objects.
- The Trivy image gate blocks CRITICAL only; ratchet to HIGH as base-image
  churn allows (the IaC gate already blocks HIGH+).
