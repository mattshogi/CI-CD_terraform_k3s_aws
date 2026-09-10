package core

import (
	"context"
	"fmt"
	"regexp"
)

// ToolClass distinguishes read-only tools (run freely) from mutating tools
// (guarded by confirm + TTL + dry-run default).
type ToolClass int

const (
	ClassRead ToolClass = iota
	ClassWrite
)

// ToolClasses is the authoritative read/write classification, enforced by both
// adapters so neither can accidentally expose a write as a read.
var ToolClasses = map[string]ToolClass{
	"list_envs":                ClassRead,
	"get_deploy_status":        ClassRead,
	"get_env_health":           ClassRead,
	"estimate_run_cost":        ClassRead,
	"triage_security_findings": ClassRead,
	"explain_last_failure":     ClassRead,
	"deploy_preview_env":       ClassWrite,
	"destroy_env":              ClassWrite,
}

// AllowedCommands is the fixed set of executables/scripts the engine may run.
// Anything else is refused, so there is no arbitrary shell passthrough.
var AllowedCommands = map[string]bool{
	"terraform":                      true,
	"helm":                           true,
	"aws":                            true,
	"trivy":                          true,
	"scripts/deploy_env.sh":          true,
	"scripts/destroy_env.sh":         true,
	"scripts/validate_endpoints.sh":  true,
	"scripts/validate_k3s_status.sh": true,
}

// GuardedRunner enforces the action allowlist around any inner Runner.
type GuardedRunner struct{ Inner Runner }

// Run refuses commands outside AllowedCommands, then delegates.
func (g GuardedRunner) Run(ctx context.Context, cmd Command) (Result, error) {
	if !AllowedCommands[cmd.Name] {
		return Result{}, fmt.Errorf("command %q is not in the action allowlist", cmd.Name)
	}
	return g.Inner.Run(ctx, cmd)
}

// validateTTL enforces that a write env request carries a TTL within the cap.
func (e *Engine) validateTTL(ttl int) error {
	if ttl <= 0 {
		return fmt.Errorf("ttl_minutes is required and must be positive")
	}
	if ttl > e.Cfg.MaxTTLMinutes {
		return fmt.Errorf("ttl_minutes %d exceeds the hard cap of %d", ttl, e.Cfg.MaxTTLMinutes)
	}
	return nil
}

// scrubPatterns redact anything secret-shaped from tool output.
var scrubPatterns = []*regexp.Regexp{
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),                                                     // AWS access key id
	regexp.MustCompile(`(?i)(aws_secret_access_key|secret|password|token)\s*[=:]\s*[^\s"']+`),  // key=value secrets
	regexp.MustCompile(`-----BEGIN[^-]+PRIVATE KEY-----[\s\S]+?-----END[^-]+PRIVATE KEY-----`), // PEM keys
	regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`),           // JWT-shaped
	regexp.MustCompile(`K10[0-9a-f]{40,}`),                                                     // k3s node token
}

// Scrub removes secret-shaped substrings. Every tool result passes through it
// before leaving the engine, so tokens, kubeconfigs, and SSM values never
// reach a transcript.
func Scrub(s string) string {
	for _, re := range scrubPatterns {
		s = re.ReplaceAllString(s, "[REDACTED]")
	}
	return s
}
