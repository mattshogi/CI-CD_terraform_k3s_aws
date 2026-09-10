// Package core holds all real logic for the agent-operable platform layer.
// The CLI and the MCP server are thin adapters over this package, so there is
// one code path for humans and agents alike (mirroring the repo's "one Helm
// chart is the only deployment definition" decision).
package core

import (
	"math"
	"os"
	"path/filepath"
	"time"
)

// Config holds the engine's runtime settings, sourced from the environment
// with safe defaults.
type Config struct {
	RepoRoot      string
	StateBucket   string // TF_STATE_BUCKET; required for env/status tools
	Region        string // AWS_REGION
	MaxTTLMinutes int    // hard cap on deploy TTL
	MaxActiveEnvs int    // concurrency cap on live envs
	ImageRepo     string
}

// DefaultConfig builds a Config from the environment.
func DefaultConfig() Config {
	root := envOr("PLATFORMCTL_REPO_ROOT", "")
	if root == "" {
		if wd, err := os.Getwd(); err == nil {
			root = findRepoRoot(wd)
		}
	}
	return Config{
		RepoRoot:      root,
		StateBucket:   os.Getenv("TF_STATE_BUCKET"),
		Region:        envOr("AWS_REGION", "us-east-1"),
		MaxTTLMinutes: 120,
		MaxActiveEnvs: 2,
		ImageRepo:     "ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world",
	}
}

// Engine is the single entry point every tool hangs off of.
type Engine struct {
	Cfg    Config
	Runner Runner
	Now    func() time.Time
}

// New wraps the runner in the action allowlist and returns a ready Engine.
func New(cfg Config, r Runner) *Engine {
	return &Engine{Cfg: cfg, Runner: GuardedRunner{Inner: r}, Now: time.Now}
}

// stateKey is the per-run S3 key for an env's Terraform state.
func stateKey(runID string) string { return "ephemeral/" + runID + ".tfstate" }

// metaKey is the per-run S3 key for an env's TTL/topology sidecar.
func metaKey(runID string) string { return "ephemeral/" + runID + ".meta.json" }

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// findRepoRoot walks up from start looking for the infra/ + scripts/ markers.
func findRepoRoot(start string) string {
	dir := start
	for i := 0; i < 12; i++ {
		if isDir(filepath.Join(dir, "infra")) && isDir(filepath.Join(dir, "scripts")) {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return start
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func round2(f float64) float64 { return math.Round(f*100) / 100 }
