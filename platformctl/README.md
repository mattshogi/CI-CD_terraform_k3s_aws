# platformctl

An agent-operable ops layer for this platform. It lets a person (via a CLI) or
an AI agent (via an MCP client such as Claude Code or Cursor) drive the
ephemeral k3s environments safely and cheaply, through one guarded code path.

The design follows the repo's "single source of truth" habit: all real logic
lives in `core/`, and both the CLI and the MCP server are thin adapters over
it. Neither adapter holds any logic of its own, so they cannot drift.

## Safety model

Read is free, write is guarded.

- Read tools (status, health, cost, triage, explain, list) run with no
  confirmation and never mutate anything.
- Write tools (deploy, destroy) default to a dry-run. They mutate only with
  `confirm=true`.
- `deploy_preview_env` requires a `ttl_minutes` within a hard cap (120), writes
  a TTL sidecar so the env auto-destroys even if the process goes away, and is
  refused when the concurrency cap (2 live envs) is reached.
- The engine can only run a fixed allowlist of commands (terraform, helm, aws,
  trivy, and the repo scripts). There is no arbitrary shell passthrough.
- Every result is scrubbed for secret-shaped strings before it leaves the
  engine, so tokens, kubeconfigs, and Parameter Store values never reach a
  transcript.

## Tools

| Tool | Class | What it does |
| --- | --- | --- |
| `list_envs` | read | Active ephemeral envs from the state bucket |
| `get_deploy_status` | read | Resource count and outputs from a run's state |
| `get_env_health` | read | HTTP reachability of the env endpoint |
| `estimate_run_cost` | read | Cents for an instance type and duration |
| `triage_security_findings` | read | Ranked, deduped Trivy findings |
| `explain_last_failure` | read | Rule-based root cause of a failed run |
| `deploy_preview_env` | write | Provision an env (dry-run unless confirmed) |
| `destroy_env` | write | Tear down an env (dry-run unless confirmed) |

## Build and run the CLI

```bash
cd platformctl
go build -o platformctl ./cli

# read tools
./platformctl cost t3.medium ha 20
./platformctl triage --image ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world:main
./platformctl explain ../terraform-apply.log
./platformctl list-envs          # needs TF_STATE_BUCKET + AWS creds
./platformctl status <run_id>

# write tools (dry-run by default)
./platformctl deploy --topology single --ttl 30          # plan only
./platformctl deploy --topology single --ttl 30 --confirm # applies, auto-destroys after TTL
./platformctl destroy <run_id> --confirm
```

Run it from anywhere inside the repo; it finds the repo root by walking up to
the `infra/` and `scripts/` markers.

## Run the MCP server

```bash
cd platformctl
go build -o platformctl-mcp ./mcp
```

Point an MCP client at the binary over stdio. For Claude Code, add it to your
MCP config:

```json
{
  "mcpServers": {
    "platformctl": {
      "command": "/absolute/path/to/platformctl-mcp",
      "env": { "TF_STATE_BUCKET": "tfstate-<account>-us-east-1", "AWS_REGION": "us-east-1" }
    }
  }
}
```

Then ask the agent things like:

- "List the active ephemeral envs and estimate what a 20-minute HA run costs."
- "Triage the security findings for the hello-world image and rank them."
- "Deploy a single-node preview with a 30-minute TTL, dry-run first, then apply
  once I confirm."
- "Explain why the last deploy failed."

The agent gets a plan before anything is created, cannot exceed the TTL cap,
and cannot run any command outside the allowlist.

## AI features (optional, off by default)

Some tools can be AI-enhanced, but AI is off unless you turn it on, and every
one falls back to deterministic output when it is off or errors. With no
configuration the repo runs at $0 and makes no network call to any AI provider.

Enhanced surfaces:

- `explain` / `explain_last_failure`: the rule-based diagnosis is the fallback;
  a provider adds a cleaner narrative from the same log.
- `summarize-findings`: a ranked plain-language findings summary (the
  deterministic ranking is the fallback). Used by the `ai-review` workflow.
- `summarize-deploy`: a short deploy summary (a template is the fallback). Used
  by the deploy workflow's job summary.

Turn it on with an environment variable:

| Env var | Effect |
| --- | --- |
| `PLATFORMCTL_AI` | `none` (default), `byok`, or `local` |
| `PLATFORMCTL_AI_API_KEY` | key for `byok` (Anthropic or OpenAI); never logged |
| `PLATFORMCTL_AI_PROVIDER` | `anthropic` (default) or `openai` for `byok` |
| `PLATFORMCTL_AI_MODEL` | model id override |
| `PLATFORMCTL_AI_OLLAMA_URL` | Ollama URL for `local` (default `http://localhost:11434`) |
| `PLATFORMCTL_AI_CACHE` | cache directory override |

The $0 local path uses Ollama:

```bash
ollama serve && ollama pull llama3.2
PLATFORMCTL_AI=local ./platformctl summarize-findings trivy.json
```

Cost is bounded per call: inputs are truncated to a character ceiling, outputs
are capped, and identical requests are served from an on-disk content cache so
the same diff is never paid for twice.

## Configuration

| Env var | Purpose | Default |
| --- | --- | --- |
| `TF_STATE_BUCKET` | State bucket for env/status tools | (required for those) |
| `AWS_REGION` | Region | `us-east-1` |
| `PLATFORMCTL_REPO_ROOT` | Override repo root detection | auto-detected |

Credentials come from the ambient AWS environment (SSO, OIDC in CI, or a
profile). platformctl adds no new standing credentials.

## Tests

```bash
go test ./...
```

Tests use a mocked exec layer and fixture Trivy/log/state data, so they make
zero cloud calls and run for free in CI.
