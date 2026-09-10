package core

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// DeployStatus summarizes an env's Terraform state without mutating anything.
type DeployStatus struct {
	RunID         string            `json:"run_id"`
	Exists        bool              `json:"exists"`
	ResourceCount int               `json:"resource_count"`
	Outputs       map[string]string `json:"outputs"`
}

// tfState is the subset of Terraform state we read.
type tfState struct {
	Resources []struct {
		Instances []json.RawMessage `json:"instances"`
	} `json:"resources"`
	Outputs map[string]struct {
		Value json.RawMessage `json:"value"`
	} `json:"outputs"`
}

// GetDeployStatus downloads the per-run state object and reports resource count
// and key outputs. Read-only: it never runs terraform.
func (e *Engine) GetDeployStatus(ctx context.Context, runID string) (DeployStatus, error) {
	if e.Cfg.StateBucket == "" {
		return DeployStatus{}, fmt.Errorf("TF_STATE_BUCKET is not set")
	}
	uri := fmt.Sprintf("s3://%s/%s", e.Cfg.StateBucket, stateKey(runID))
	res, err := e.Runner.Run(ctx, Command{
		Name: "aws",
		Args: []string{"s3", "cp", uri, "-", "--region", e.Cfg.Region},
	})
	if err != nil {
		// Missing object is a normal "no such env" answer, not a failure.
		return DeployStatus{RunID: runID, Exists: false, Outputs: map[string]string{}}, nil
	}
	var st tfState
	if err := json.Unmarshal([]byte(res.Stdout), &st); err != nil {
		return DeployStatus{}, fmt.Errorf("parse state: %w", err)
	}
	count := 0
	for _, r := range st.Resources {
		count += len(r.Instances)
	}
	outputs := map[string]string{}
	for _, k := range []string{"server_public_ip", "endpoint_host", "ha_mode", "server_instance_ids"} {
		if o, ok := st.Outputs[k]; ok {
			outputs[k] = strings.Trim(string(o.Value), `"`)
		}
	}
	return DeployStatus{RunID: runID, Exists: true, ResourceCount: count, Outputs: outputs}, nil
}

// EnvHealth is the reachability result for an env's public endpoint.
type EnvHealth struct {
	RunID     string `json:"run_id"`
	Endpoint  string `json:"endpoint"`
	Reachable bool   `json:"reachable"`
	Detail    string `json:"detail"`
}

// GetEnvHealth resolves the env's endpoint from state, then reuses the existing
// validate_endpoints.sh to check HTTP reachability. (Pod-level detail is
// available over SSM; kept out of Stage 1 to stay deterministic and cloud-free
// in tests.)
func (e *Engine) GetEnvHealth(ctx context.Context, runID string) (EnvHealth, error) {
	st, err := e.GetDeployStatus(ctx, runID)
	if err != nil {
		return EnvHealth{}, err
	}
	if !st.Exists {
		return EnvHealth{RunID: runID, Reachable: false, Detail: "no state for this run id"}, nil
	}
	host := st.Outputs["endpoint_host"]
	if host == "" {
		host = st.Outputs["server_public_ip"]
	}
	if host == "" {
		return EnvHealth{RunID: runID, Reachable: false, Detail: "no endpoint in state outputs"}, nil
	}
	res, err := e.Runner.Run(ctx, Command{
		Name: "scripts/validate_endpoints.sh",
		Args: []string{host, "3", "5"},
	})
	reachable := err == nil
	detail := "endpoint answered"
	if !reachable {
		detail = "endpoint did not answer within the retry window"
	}
	_ = res
	return EnvHealth{RunID: runID, Endpoint: host, Reachable: reachable, Detail: detail}, nil
}
