package core

import (
	"context"
	"strings"
	"testing"
)

func TestAllowlistRejectsArbitraryCommand(t *testing.T) {
	g := GuardedRunner{Inner: &mockRunner{}}
	_, err := g.Run(context.Background(), Command{Name: "rm", Args: []string{"-rf", "/"}})
	if err == nil || !strings.Contains(err.Error(), "allowlist") {
		t.Fatalf("expected allowlist rejection, got %v", err)
	}
}

func TestAllowlistPermitsKnownCommand(t *testing.T) {
	g := GuardedRunner{Inner: &mockRunner{fn: func(Command) (Result, error) { return Result{Stdout: "ok"}, nil }}}
	res, err := g.Run(context.Background(), Command{Name: "terraform", Args: []string{"version"}})
	if err != nil || res.Stdout != "ok" {
		t.Fatalf("expected pass-through, got %v / %q", err, res.Stdout)
	}
}

func TestScrubRedactsSecrets(t *testing.T) {
	in := "key AKIAIOSFODNN7EXAMPLE and token=supersecretvalue and K10" + strings.Repeat("a", 50) + " done"
	out := Scrub(in)
	if strings.Contains(out, "AKIAIOSFODNN7EXAMPLE") || strings.Contains(out, "supersecretvalue") {
		t.Errorf("secrets not scrubbed: %q", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Errorf("expected redaction marker: %q", out)
	}
}

func TestValidateTTL(t *testing.T) {
	e, _ := testEngine(nil)
	if err := e.validateTTL(0); err == nil {
		t.Error("expected error for zero ttl")
	}
	if err := e.validateTTL(999); err == nil {
		t.Error("expected error for ttl over cap")
	}
	if err := e.validateTTL(60); err != nil {
		t.Errorf("expected 60 to be valid, got %v", err)
	}
}
