package core

import (
	"context"
	"fmt"
	"testing"
)

func TestDeployRejectsBadInput(t *testing.T) {
	e, _ := testEngine(nil)
	ctx := context.Background()
	if _, err := e.DeployPreviewEnv(ctx, DeployRequest{Topology: "bogus", TTLMinutes: 60}); err == nil {
		t.Error("expected error for bad topology")
	}
	if _, err := e.DeployPreviewEnv(ctx, DeployRequest{Topology: "single"}); err == nil {
		t.Error("expected error for missing ttl_minutes")
	}
	if _, err := e.DeployPreviewEnv(ctx, DeployRequest{Topology: "single", TTLMinutes: 999}); err == nil {
		t.Error("expected error for ttl over cap")
	}
}

func TestDeployDryRunDefault(t *testing.T) {
	e, m := testEngine(func(c Command) (Result, error) {
		if c.Name == "scripts/deploy_env.sh" {
			if !hasEnv(c, "MODE=plan") {
				return Result{}, fmt.Errorf("dry-run must use MODE=plan")
			}
			return Result{Stdout: "Terraform will perform the following actions ..."}, nil
		}
		return Result{}, nil
	})
	r, err := e.DeployPreviewEnv(context.Background(), DeployRequest{Topology: "single", TTLMinutes: 60, Confirm: false})
	if err != nil {
		t.Fatal(err)
	}
	if !r.DryRun || r.Applied || r.Plan == "" {
		t.Errorf("expected dry-run with plan, got %+v", r)
	}
	for _, c := range m.calls {
		if c.Name == "aws" && argsContain(c, ".meta.json") {
			t.Error("dry-run must not write a TTL sidecar")
		}
	}
}

func TestDeployConfirmApplies(t *testing.T) {
	e, m := testEngine(func(c Command) (Result, error) {
		switch {
		case c.Name == "aws" && len(c.Args) > 1 && c.Args[1] == "ls":
			return Result{Stdout: ""}, nil // no active envs
		case c.Name == "aws" && argsContain(c, ".meta.json"):
			return Result{}, nil // writeMeta cp success
		case c.Name == "scripts/deploy_env.sh":
			if !hasEnv(c, "MODE=apply") || !hasEnv(c, "TF_VAR_ha_mode=true") {
				return Result{}, fmt.Errorf("expected apply + ha_mode")
			}
			return Result{Stdout: "server_ip=203.0.113.10\ninstance_id=i-0abc\nendpoint_host=203.0.113.10"}, nil
		}
		return Result{}, nil
	})
	r, err := e.DeployPreviewEnv(context.Background(), DeployRequest{Topology: "ha", TTLMinutes: 60, Confirm: true})
	if err != nil {
		t.Fatal(err)
	}
	if !r.Applied || r.Outputs["server_ip"] != "203.0.113.10" {
		t.Errorf("expected applied with outputs, got %+v", r)
	}
	wroteMeta := false
	for _, c := range m.calls {
		if c.Name == "aws" && argsContain(c, ".meta.json") {
			wroteMeta = true
		}
	}
	if !wroteMeta {
		t.Error("confirmed apply must write a TTL sidecar")
	}
}

func TestDeployConcurrencyCap(t *testing.T) {
	listing := "2026-01-01 00:00:00 100 aaa.tfstate\n2026-01-01 00:00:00 100 bbb.tfstate\n"
	futureMeta := `{"run_id":"x","expires_at":"2099-01-01T00:00:00Z","topology":"single"}`
	e, _ := testEngine(func(c Command) (Result, error) {
		if c.Name == "aws" && len(c.Args) > 1 && c.Args[1] == "ls" {
			return Result{Stdout: listing}, nil
		}
		if c.Name == "aws" && argsContain(c, ".meta.json") {
			return Result{Stdout: futureMeta}, nil
		}
		return Result{}, nil
	})
	_, err := e.DeployPreviewEnv(context.Background(), DeployRequest{Topology: "single", TTLMinutes: 60, Confirm: true})
	if err == nil {
		t.Fatal("expected concurrency cap rejection")
	}
}

func TestDestroyDryRun(t *testing.T) {
	e, _ := testEngine(func(c Command) (Result, error) {
		if c.Name == "aws" && argsContain(c, ".tfstate") {
			return Result{Stdout: `{"resources":[{"instances":[{}]},{"instances":[{}]}],"outputs":{}}`}, nil
		}
		return Result{}, nil
	})
	r, err := e.DestroyEnv(context.Background(), "run1", false)
	if err != nil {
		t.Fatal(err)
	}
	if !r.DryRun || r.Destroyed {
		t.Errorf("expected dry-run without destruction, got %+v", r)
	}
}

func TestDestroyConfirm(t *testing.T) {
	e, m := testEngine(func(c Command) (Result, error) {
		if c.Name == "aws" && argsContain(c, ".meta.json") {
			return Result{Stdout: `{"topology":"ha"}`}, nil // readMeta -> ha
		}
		if c.Name == "scripts/destroy_env.sh" {
			if !hasEnv(c, "TF_VAR_ha_mode=true") {
				return Result{}, fmt.Errorf("destroy should match ha topology")
			}
			return Result{}, nil
		}
		return Result{}, nil // s3 rm
	})
	r, err := e.DestroyEnv(context.Background(), "run1", true)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Destroyed {
		t.Errorf("expected destroyed, got %+v", r)
	}
	rmCount := 0
	for _, c := range m.calls {
		if c.Name == "aws" && len(c.Args) > 1 && c.Args[1] == "rm" {
			rmCount++
		}
	}
	if rmCount != 2 {
		t.Errorf("expected state + meta cleanup (2 rm calls), got %d", rmCount)
	}
}
