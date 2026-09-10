package core

import (
	"context"
	"fmt"
	"os"
	"testing"
)

func TestGetDeployStatus(t *testing.T) {
	state, _ := os.ReadFile("../testdata/state.json")
	e, _ := testEngine(func(c Command) (Result, error) {
		if c.Name == "aws" && argsContain(c, ".tfstate") {
			return Result{Stdout: string(state)}, nil
		}
		return Result{}, nil
	})
	st, err := e.GetDeployStatus(context.Background(), "run1")
	if err != nil {
		t.Fatal(err)
	}
	if !st.Exists || st.ResourceCount != 2 {
		t.Errorf("expected exists + 2 resources, got %+v", st)
	}
	if st.Outputs["endpoint_host"] != "203.0.113.10" || st.Outputs["ha_mode"] != "false" {
		t.Errorf("outputs wrong: %+v", st.Outputs)
	}
}

func TestGetDeployStatusMissing(t *testing.T) {
	e, _ := testEngine(func(c Command) (Result, error) {
		return Result{}, fmt.Errorf("NoSuchKey")
	})
	st, err := e.GetDeployStatus(context.Background(), "nope")
	if err != nil {
		t.Fatalf("missing env should not error: %v", err)
	}
	if st.Exists {
		t.Errorf("expected Exists=false for missing state")
	}
}

func TestGetEnvHealth(t *testing.T) {
	state, _ := os.ReadFile("../testdata/state.json")
	e, _ := testEngine(func(c Command) (Result, error) {
		if c.Name == "aws" && argsContain(c, ".tfstate") {
			return Result{Stdout: string(state)}, nil
		}
		if c.Name == "scripts/validate_endpoints.sh" {
			return Result{Stdout: "reachable"}, nil
		}
		return Result{}, nil
	})
	h, err := e.GetEnvHealth(context.Background(), "run1")
	if err != nil {
		t.Fatal(err)
	}
	if !h.Reachable || h.Endpoint != "203.0.113.10" {
		t.Errorf("expected reachable at 203.0.113.10, got %+v", h)
	}
}
