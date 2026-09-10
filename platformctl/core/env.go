package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// Env is one ephemeral environment as seen from remote state.
type Env struct {
	RunID     string    `json:"run_id"`
	Topology  string    `json:"topology,omitempty"`
	ExpiresAt time.Time `json:"expires_at,omitempty"`
	Expired   bool      `json:"expired"`
}

// envMeta is the TTL/topology sidecar object written next to each env's state.
// It carries the auto-destroy contract so no standing infra is needed: a free
// cron workflow (reaper.yml) reaps envs whose ExpiresAt has passed.
type envMeta struct {
	RunID     string    `json:"run_id"`
	ExpiresAt time.Time `json:"expires_at"`
	Topology  string    `json:"topology"`
}

// ListEnvs enumerates active ephemeral envs from the state bucket.
func (e *Engine) ListEnvs(ctx context.Context) ([]Env, error) {
	if e.Cfg.StateBucket == "" {
		return nil, fmt.Errorf("TF_STATE_BUCKET is not set")
	}
	res, err := e.Runner.Run(ctx, Command{
		Name: "aws",
		Args: []string{"s3", "ls", fmt.Sprintf("s3://%s/ephemeral/", e.Cfg.StateBucket), "--region", e.Cfg.Region},
	})
	if err != nil {
		return nil, err
	}
	var envs []Env
	for _, id := range runIDsFromListing(res.Stdout) {
		env := Env{RunID: id}
		if m, ok := e.readMeta(ctx, id); ok {
			env.Topology = m.Topology
			env.ExpiresAt = m.ExpiresAt
			env.Expired = !m.ExpiresAt.IsZero() && e.Now().After(m.ExpiresAt)
		}
		envs = append(envs, env)
	}
	return envs, nil
}

// runIDsFromListing parses `aws s3 ls` output for *.tfstate object names.
func runIDsFromListing(out string) []string {
	var ids []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		name := fields[len(fields)-1]
		if strings.HasSuffix(name, ".tfstate") {
			ids = append(ids, strings.TrimSuffix(name, ".tfstate"))
		}
	}
	return ids
}

func (e *Engine) readMeta(ctx context.Context, runID string) (envMeta, bool) {
	uri := fmt.Sprintf("s3://%s/%s", e.Cfg.StateBucket, metaKey(runID))
	res, err := e.Runner.Run(ctx, Command{Name: "aws", Args: []string{"s3", "cp", uri, "-", "--region", e.Cfg.Region}})
	if err != nil {
		return envMeta{}, false
	}
	var m envMeta
	if err := json.Unmarshal([]byte(res.Stdout), &m); err != nil {
		return envMeta{}, false
	}
	return m, true
}

// DeployRequest is the input to deploy_preview_env.
type DeployRequest struct {
	Topology   string `json:"topology"` // "single" | "ha"
	TTLMinutes int    `json:"ttl_minutes"`
	Confirm    bool   `json:"confirm"`
	RunID      string `json:"run_id,omitempty"`
	ImageRef   string `json:"image_ref,omitempty"`
}

// DeployResult is the output of deploy_preview_env.
type DeployResult struct {
	RunID   string            `json:"run_id"`
	DryRun  bool              `json:"dry_run"`
	Applied bool              `json:"applied"`
	Plan    string            `json:"plan,omitempty"`
	Outputs map[string]string `json:"outputs,omitempty"`
	Message string            `json:"message"`
}

// DeployPreviewEnv provisions (or plans) an ephemeral env. Dry-run is the
// default; a real apply requires confirm=true, a TTL within the cap, and free
// capacity under the concurrency limit. The TTL sidecar is written before
// apply so even a failed apply is reap-able.
func (e *Engine) DeployPreviewEnv(ctx context.Context, req DeployRequest) (DeployResult, error) {
	haMode := false
	switch req.Topology {
	case "single":
		haMode = false
	case "ha":
		haMode = true
	default:
		return DeployResult{}, fmt.Errorf("topology must be \"single\" or \"ha\"")
	}
	if err := e.validateTTL(req.TTLMinutes); err != nil {
		return DeployResult{}, err
	}
	if e.Cfg.StateBucket == "" {
		return DeployResult{}, fmt.Errorf("TF_STATE_BUCKET is not set")
	}

	runID := req.RunID
	if runID == "" {
		runID = fmt.Sprintf("pctl-%d", e.Now().Unix())
	}
	instanceType := "t3.small"
	if haMode {
		instanceType = "t3.medium"
	}
	env := []string{
		"RUN_ID=" + runID,
		"TF_STATE_BUCKET=" + e.Cfg.StateBucket,
		"AWS_REGION=" + e.Cfg.Region,
		"TF_VAR_environment=staging",
		"TF_VAR_ha_mode=" + boolStr(haMode),
		"TF_VAR_instance_type=" + instanceType,
	}
	if req.ImageRef != "" {
		env = append(env, "IMAGE_REF="+req.ImageRef)
	}

	if !req.Confirm {
		res, err := e.Runner.Run(ctx, Command{Name: "scripts/deploy_env.sh", Env: append(env, "MODE=plan")})
		if err != nil {
			return DeployResult{}, fmt.Errorf("dry-run plan failed: %w", err)
		}
		return DeployResult{
			RunID: runID, DryRun: true, Applied: false,
			Plan:    Scrub(res.Stdout),
			Message: "dry-run only; re-run with confirm=true to apply (auto-destroys after TTL)",
		}, nil
	}

	// Confirmed apply: enforce the concurrency cap on live envs.
	active, err := e.activeCount(ctx)
	if err == nil && active >= e.Cfg.MaxActiveEnvs {
		return DeployResult{}, fmt.Errorf("concurrency cap reached: %d active envs (max %d)", active, e.Cfg.MaxActiveEnvs)
	}

	expiresAt := e.Now().Add(time.Duration(req.TTLMinutes) * time.Minute)
	if err := e.writeMeta(ctx, envMeta{RunID: runID, ExpiresAt: expiresAt, Topology: req.Topology}); err != nil {
		return DeployResult{}, fmt.Errorf("write TTL sidecar: %w", err)
	}

	res, err := e.Runner.Run(ctx, Command{Name: "scripts/deploy_env.sh", Env: append(env, "MODE=apply")})
	if err != nil {
		return DeployResult{RunID: runID, Message: "apply failed; env is TTL-tagged and will be reaped"}, err
	}
	return DeployResult{
		RunID: runID, DryRun: false, Applied: true,
		Outputs: parseKV(res.Stdout),
		Message: fmt.Sprintf("applied; auto-destroys at %s", expiresAt.UTC().Format(time.RFC3339)),
	}, nil
}

func (e *Engine) activeCount(ctx context.Context) (int, error) {
	envs, err := e.ListEnvs(ctx)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, env := range envs {
		if !env.Expired {
			n++
		}
	}
	return n, nil
}

func (e *Engine) writeMeta(ctx context.Context, m envMeta) error {
	f, err := os.CreateTemp("", "pctl-meta-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := json.NewEncoder(f).Encode(m); err != nil {
		f.Close()
		return err
	}
	f.Close()
	uri := fmt.Sprintf("s3://%s/%s", e.Cfg.StateBucket, metaKey(m.RunID))
	_, err = e.Runner.Run(ctx, Command{Name: "aws", Args: []string{"s3", "cp", f.Name(), uri, "--region", e.Cfg.Region}})
	return err
}

// DestroyResult is the output of destroy_env.
type DestroyResult struct {
	RunID     string `json:"run_id"`
	DryRun    bool   `json:"dry_run"`
	Destroyed bool   `json:"destroyed"`
	Message   string `json:"message"`
}

// DestroyEnv tears down an env by run id. Without confirm it reports what would
// be destroyed; with confirm=true it runs the shared destroy script and removes
// the state and TTL objects.
func (e *Engine) DestroyEnv(ctx context.Context, runID string, confirm bool) (DestroyResult, error) {
	if e.Cfg.StateBucket == "" {
		return DestroyResult{}, fmt.Errorf("TF_STATE_BUCKET is not set")
	}
	if !confirm {
		st, err := e.GetDeployStatus(ctx, runID)
		if err != nil {
			return DestroyResult{}, err
		}
		msg := fmt.Sprintf("dry-run: would destroy %d resources; re-run with confirm=true", st.ResourceCount)
		if !st.Exists {
			msg = "dry-run: no state found for this run id"
		}
		return DestroyResult{RunID: runID, DryRun: true, Destroyed: false, Message: msg}, nil
	}

	// Match the applied topology so the destroy plan lines up.
	haMode := false
	if m, ok := e.readMeta(ctx, runID); ok && m.Topology == "ha" {
		haMode = true
	}
	env := []string{
		"RUN_ID=" + runID,
		"TF_STATE_BUCKET=" + e.Cfg.StateBucket,
		"AWS_REGION=" + e.Cfg.Region,
		"TF_VAR_ha_mode=" + boolStr(haMode),
	}
	if _, err := e.Runner.Run(ctx, Command{Name: "scripts/destroy_env.sh", Env: env}); err != nil {
		return DestroyResult{RunID: runID}, fmt.Errorf("destroy failed: %w", err)
	}
	// Remove state + TTL objects so the env drops out of listings.
	for _, key := range []string{stateKey(runID), metaKey(runID)} {
		uri := fmt.Sprintf("s3://%s/%s", e.Cfg.StateBucket, key)
		_, _ = e.Runner.Run(ctx, Command{Name: "aws", Args: []string{"s3", "rm", uri, "--region", e.Cfg.Region}})
	}
	return DestroyResult{RunID: runID, DryRun: false, Destroyed: true, Message: "destroyed and state cleaned"}, nil
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func parseKV(s string) map[string]string {
	m := map[string]string{}
	for _, ln := range strings.Split(s, "\n") {
		i := strings.Index(ln, "=")
		if i <= 0 {
			continue
		}
		k := strings.TrimSpace(ln[:i])
		switch k {
		case "server_ip", "instance_id", "endpoint_host", "instance_ids", "app_image":
			m[k] = strings.TrimSpace(ln[i+1:])
		}
	}
	return m
}
