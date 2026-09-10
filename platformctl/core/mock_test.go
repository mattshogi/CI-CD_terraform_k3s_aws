package core

import (
	"context"
	"strings"
	"time"
)

// mockRunner records calls and returns canned results, so no test touches AWS.
type mockRunner struct {
	fn    func(Command) (Result, error)
	calls []Command
}

func (m *mockRunner) Run(_ context.Context, c Command) (Result, error) {
	m.calls = append(m.calls, c)
	if m.fn != nil {
		return m.fn(c)
	}
	return Result{}, nil
}

// testEngine builds an Engine with a mocked runner and a fixed clock.
func testEngine(fn func(Command) (Result, error)) (*Engine, *mockRunner) {
	m := &mockRunner{fn: fn}
	cfg := Config{
		RepoRoot:      "/repo",
		StateBucket:   "bkt",
		Region:        "us-east-1",
		MaxTTLMinutes: 120,
		MaxActiveEnvs: 2,
		ImageRepo:     "ghcr.io/mattshogi/ci-cd_terraform_k3s_aws/hello-world",
	}
	e := New(cfg, m)
	e.Now = func() time.Time { return time.Unix(1_000_000_000, 0).UTC() }
	return e, m
}

func hasEnv(c Command, kv string) bool {
	for _, v := range c.Env {
		if v == kv {
			return true
		}
	}
	return false
}

func argsContain(c Command, sub string) bool {
	for _, a := range c.Args {
		if strings.Contains(a, sub) {
			return true
		}
	}
	return false
}
