package ai

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/mattshogi/CI-CD_terraform_k3s_aws/platformctl/core"
)

func TestNoneReturnsFallback(t *testing.T) {
	out, err := None{}.Summarize(context.Background(), Request{Fallback: "deterministic"})
	if err != nil || out != "deterministic" {
		t.Fatalf("none must return fallback, got %q / %v", out, err)
	}
}

func TestFromEnvDefaultsToNone(t *testing.T) {
	t.Setenv("PLATFORMCTL_AI", "")
	if FromEnv().Name() != "none" {
		t.Errorf("default provider must be none")
	}
}

func TestBYOKWithoutKeyFallsBack(t *testing.T) {
	t.Setenv("PLATFORMCTL_AI_API_KEY", "")
	out, err := NewBYOK().Summarize(context.Background(), Request{Fallback: "fb"})
	if err != nil || out != "fb" {
		t.Fatalf("no key must fall back with no network, got %q / %v", out, err)
	}
}

func TestTruncate(t *testing.T) {
	if got := Truncate("abcdef", 3); !strings.HasPrefix(got, "abc") || !strings.Contains(got, "truncated") {
		t.Errorf("unexpected truncation: %q", got)
	}
	if got := Truncate("ab", 10); got != "ab" {
		t.Errorf("short input should pass through, got %q", got)
	}
}

type countStub struct{ n *int }

func (countStub) Name() string { return "stub" }
func (c countStub) Summarize(_ context.Context, req Request) (string, error) {
	*c.n++
	return "AI:" + req.Task, nil
}

func TestCacheServesSecondCall(t *testing.T) {
	t.Setenv("PLATFORMCTL_AI_CACHE", t.TempDir())
	n := 0
	c := WithBudget(countStub{&n})
	req := Request{Task: "x", Prompt: "p", Fallback: "fb"}
	if out, _ := c.Summarize(context.Background(), req); out != "AI:x" {
		t.Fatalf("first call: %q", out)
	}
	if out, _ := c.Summarize(context.Background(), req); out != "AI:x" {
		t.Fatalf("second call: %q", out)
	}
	if n != 1 {
		t.Errorf("expected 1 provider call (second cached), got %d", n)
	}
}

type errStub struct{}

func (errStub) Name() string { return "err" }
func (errStub) Summarize(_ context.Context, _ Request) (string, error) {
	return "", fmt.Errorf("boom")
}

func TestErrorFallsBack(t *testing.T) {
	t.Setenv("PLATFORMCTL_AI_CACHE", t.TempDir())
	c := WithBudget(errStub{})
	out, err := c.Summarize(context.Background(), Request{Fallback: "FALLBACK"})
	if err != nil || out != "FALLBACK" {
		t.Errorf("provider error must fall back, got %q / %v", out, err)
	}
}

func TestFormatFindings(t *testing.T) {
	tr := core.TriageResult{
		Total:  2,
		Counts: map[string]int{"CRITICAL": 1, "MEDIUM": 1},
		Findings: []core.Finding{
			{ID: "CVE-1", Severity: "CRITICAL", Target: "img", Fix: "upgrade to 2.0"},
			{ID: "AVD-1", Severity: "MEDIUM", Target: "main.tf"},
		},
	}
	out := FormatFindings(tr)
	if !strings.Contains(out, "CRITICAL") || !strings.Contains(out, "CVE-1") {
		t.Errorf("summary missing key content: %q", out)
	}
}

func TestFormatDeploy(t *testing.T) {
	out := FormatDeploy(DeploySummary{RunID: "r1", Image: "img:sha", Endpoint: "1.2.3.4", Reachable: true, CostCents: 4.9})
	if !strings.Contains(out, "r1") || !strings.Contains(out, "reachable") {
		t.Errorf("deploy summary missing content: %q", out)
	}
}
