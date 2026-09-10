// Package ai adds optional, opt-in AI assistance over the platform core. It is
// off by default: with no provider configured (PLATFORMCTL_AI unset or "none"),
// every function returns the deterministic Stage 1 text, makes no network call,
// and costs nothing. A provider only ever enhances output; on any error it
// falls back to the deterministic text, so an AI outage never fails a pipeline.
package ai

import (
	"context"
	"os"
	"strings"
)

// Request is one summarization ask. Fallback is the deterministic text returned
// whenever AI is off or errors, so callers always get a useful answer.
type Request struct {
	Task     string // "security-findings" | "failure" | "deploy-summary"
	Prompt   string // content to summarize
	Fallback string // deterministic text used when AI is off or errors
}

// Provider turns a Request into prose.
type Provider interface {
	Name() string
	Summarize(ctx context.Context, req Request) (string, error)
}

// None is the default provider: it returns the deterministic fallback and
// never touches the network.
type None struct{}

// Name identifies the provider.
func (None) Name() string { return "none" }

// Summarize returns the caller's deterministic fallback unchanged.
func (None) Summarize(_ context.Context, req Request) (string, error) {
	return req.Fallback, nil
}

// FromEnv selects a provider from PLATFORMCTL_AI (none|byok|local). Unknown or
// empty means None. byok and local are wrapped with the budget/cache decorator;
// None needs neither.
func FromEnv() Provider {
	switch strings.ToLower(os.Getenv("PLATFORMCTL_AI")) {
	case "byok":
		return WithBudget(NewBYOK())
	case "local":
		return WithBudget(NewLocal())
	default:
		return None{}
	}
}

// systemFor returns the system instruction for a task.
func systemFor(task string) string {
	switch task {
	case "security-findings":
		return "You are a DevOps security assistant. Given Trivy findings, write a short, ranked, plain-language summary: most urgent first, one concrete action each. No preamble."
	case "failure":
		return "You are an SRE. Given a failed deploy log and a rule-based classification, explain the root cause in two or three sentences and give the single best next step. No preamble."
	case "deploy-summary":
		return "You are a release assistant. Given deploy facts, write a two or three sentence human-readable summary. No preamble."
	default:
		return "Summarize the input concisely and plainly."
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
