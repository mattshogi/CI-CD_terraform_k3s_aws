// Command platformctl-mcp is the agent-facing adapter over the platform core.
// It exposes the same tools the CLI does, over MCP stdio, so an MCP client
// (Claude Code, Cursor, any) drives the platform through the identical guarded
// code path. Read tools run freely; write tools default to a dry-run and only
// mutate with confirm=true.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/mattshogi/CI-CD_terraform_k3s_aws/platformctl/core"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	cfg := core.DefaultConfig()
	engine := core.New(cfg, core.ExecRunner{BaseDir: cfg.RepoRoot})

	s := mcp.NewServer(&mcp.Implementation{Name: "platformctl", Version: "0.1.0"}, nil)
	registerTools(s, engine, cfg)

	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatalf("platformctl-mcp: %v", err)
	}
}

// reply builds a tool result: scrubbed JSON text plus the structured value.
func reply[T any](v T) (*mcp.CallToolResult, T, error) {
	b, _ := json.MarshalIndent(v, "", "  ")
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: core.Scrub(string(b))}},
	}, v, nil
}

type runIDInput struct {
	RunID string `json:"run_id" jsonschema:"the ephemeral run id"`
}
type emptyInput struct{}
type costInput struct {
	InstanceType string `json:"instance_type" jsonschema:"EC2 instance type, e.g. t3.small"`
	HAMode       bool   `json:"ha_mode" jsonschema:"true for a 3-node HA cluster"`
	Minutes      int    `json:"minutes" jsonschema:"run duration in minutes"`
}
type triageInput struct {
	Image     string `json:"image,omitempty" jsonschema:"image ref to scan with trivy"`
	TrivyJSON string `json:"trivy_json,omitempty" jsonschema:"raw trivy JSON to parse instead of scanning"`
}
type explainInput struct {
	Log string `json:"log,omitempty" jsonschema:"failing-run log text; empty reads terraform-apply.log"`
}
type deployInput struct {
	Topology   string `json:"topology" jsonschema:"single or ha"`
	TTLMinutes int    `json:"ttl_minutes" jsonschema:"required; auto-destroy after this many minutes (capped)"`
	Confirm    bool   `json:"confirm" jsonschema:"false (default) plans only; true applies"`
	ImageRef   string `json:"image_ref,omitempty" jsonschema:"optional image override"`
	RunID      string `json:"run_id,omitempty" jsonschema:"optional explicit run id"`
}
type destroyInput struct {
	RunID   string `json:"run_id" jsonschema:"the ephemeral run id to tear down"`
	Confirm bool   `json:"confirm" jsonschema:"false (default) is a dry-run; true destroys"`
}

func registerTools(s *mcp.Server, e *core.Engine, cfg core.Config) {
	mcp.AddTool(s, &mcp.Tool{Name: "list_envs", Description: "List active ephemeral environments."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ emptyInput) (*mcp.CallToolResult, []core.Env, error) {
			envs, err := e.ListEnvs(ctx)
			if err != nil {
				return nil, nil, err
			}
			return reply(envs)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_deploy_status", Description: "Terraform state summary for a run id (read-only)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in runIDInput) (*mcp.CallToolResult, core.DeployStatus, error) {
			st, err := e.GetDeployStatus(ctx, in.RunID)
			if err != nil {
				return nil, core.DeployStatus{}, err
			}
			return reply(st)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_env_health", Description: "HTTP reachability of an env's endpoint."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in runIDInput) (*mcp.CallToolResult, core.EnvHealth, error) {
			h, err := e.GetEnvHealth(ctx, in.RunID)
			if err != nil {
				return nil, core.EnvHealth{}, err
			}
			return reply(h)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "estimate_run_cost", Description: "Estimated cents for a run (instance type x duration)."},
		func(_ context.Context, _ *mcp.CallToolRequest, in costInput) (*mcp.CallToolResult, core.CostEstimate, error) {
			est, err := core.EstimateRunCost(in.InstanceType, in.HAMode, in.Minutes)
			if err != nil {
				return nil, core.CostEstimate{}, err
			}
			return reply(est)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "triage_security_findings", Description: "Rank and dedupe Trivy findings into actionable items."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in triageInput) (*mcp.CallToolResult, core.TriageResult, error) {
			switch {
			case in.Image != "":
				res, err := e.TriageImage(ctx, in.Image)
				if err != nil {
					return nil, core.TriageResult{}, err
				}
				return reply(res)
			case in.TrivyJSON != "":
				res, err := core.TriageSecurityFindings(strings.NewReader(in.TrivyJSON))
				if err != nil {
					return nil, core.TriageResult{}, err
				}
				return reply(res)
			default:
				return nil, core.TriageResult{}, fmt.Errorf("provide either image or trivy_json")
			}
		})

	mcp.AddTool(s, &mcp.Tool{Name: "explain_last_failure", Description: "Rule-based root cause of a failed run."},
		func(_ context.Context, _ *mcp.CallToolRequest, in explainInput) (*mcp.CallToolResult, core.Diagnosis, error) {
			logText := in.Log
			if logText == "" {
				if b, err := os.ReadFile(filepath.Join(cfg.RepoRoot, "terraform-apply.log")); err == nil {
					logText = string(b)
				}
			}
			return reply(core.ExplainLastFailure(logText))
		})

	mcp.AddTool(s, &mcp.Tool{Name: "deploy_preview_env", Description: "Provision an ephemeral env. Dry-run unless confirm=true; requires ttl_minutes (capped)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in deployInput) (*mcp.CallToolResult, core.DeployResult, error) {
			res, err := e.DeployPreviewEnv(ctx, core.DeployRequest{
				Topology: in.Topology, TTLMinutes: in.TTLMinutes, Confirm: in.Confirm,
				ImageRef: in.ImageRef, RunID: in.RunID,
			})
			if err != nil {
				return nil, core.DeployResult{}, err
			}
			return reply(res)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "destroy_env", Description: "Tear down an env by run id. Dry-run unless confirm=true."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in destroyInput) (*mcp.CallToolResult, core.DestroyResult, error) {
			res, err := e.DestroyEnv(ctx, in.RunID, in.Confirm)
			if err != nil {
				return nil, core.DestroyResult{}, err
			}
			return reply(res)
		})
}
