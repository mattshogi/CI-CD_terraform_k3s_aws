// Command platformctl is the human-facing adapter over the platform core. It
// is deliberately thin: every subcommand maps 1:1 to a core function, so the
// CLI and the MCP server expose identical behavior.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/mattshogi/CI-CD_terraform_k3s_aws/platformctl/core"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cfg := core.DefaultConfig()
	engine := core.New(cfg, core.ExecRunner{BaseDir: cfg.RepoRoot})
	ctx := context.Background()

	if err := dispatch(ctx, engine, os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func dispatch(ctx context.Context, e *core.Engine, cmd string, args []string) error {
	switch cmd {
	case "list-envs":
		envs, err := e.ListEnvs(ctx)
		if err != nil {
			return err
		}
		return emit(envs)

	case "status":
		if len(args) < 1 {
			return fmt.Errorf("usage: platformctl status <run_id>")
		}
		st, err := e.GetDeployStatus(ctx, args[0])
		if err != nil {
			return err
		}
		return emit(st)

	case "health":
		if len(args) < 1 {
			return fmt.Errorf("usage: platformctl health <run_id>")
		}
		h, err := e.GetEnvHealth(ctx, args[0])
		if err != nil {
			return err
		}
		return emit(h)

	case "cost":
		if len(args) < 3 {
			return fmt.Errorf("usage: platformctl cost <instance_type> <single|ha> <minutes>")
		}
		mins, err := strconv.Atoi(args[2])
		if err != nil {
			return fmt.Errorf("minutes: %w", err)
		}
		est, err := core.EstimateRunCost(args[0], args[1] == "ha", mins)
		if err != nil {
			return err
		}
		return emit(est)

	case "triage":
		fs := flag.NewFlagSet("triage", flag.ExitOnError)
		image := fs.String("image", "", "scan this image ref with trivy instead of reading a file")
		_ = fs.Parse(args)
		if *image != "" {
			res, err := e.TriageImage(ctx, *image)
			if err != nil {
				return err
			}
			return emit(res)
		}
		r, closeFn, err := openInput(fs.Arg(0))
		if err != nil {
			return err
		}
		defer closeFn()
		res, err := core.TriageSecurityFindings(r)
		if err != nil {
			return err
		}
		return emit(res)

	case "explain":
		path := ""
		if len(args) > 0 {
			path = args[0]
		} else {
			path = "terraform-apply.log"
		}
		r, closeFn, err := openInput(path)
		if err != nil {
			return err
		}
		defer closeFn()
		data, _ := io.ReadAll(r)
		return emit(core.ExplainLastFailure(string(data)))

	case "deploy":
		fs := flag.NewFlagSet("deploy", flag.ExitOnError)
		topology := fs.String("topology", "single", "single|ha")
		ttl := fs.Int("ttl", 0, "TTL in minutes (required, capped)")
		confirm := fs.Bool("confirm", false, "actually apply (default is a dry-run plan)")
		image := fs.String("image", "", "image ref override")
		runID := fs.String("run-id", "", "explicit run id (optional)")
		_ = fs.Parse(args)
		res, err := e.DeployPreviewEnv(ctx, core.DeployRequest{
			Topology: *topology, TTLMinutes: *ttl, Confirm: *confirm,
			RunID: *runID, ImageRef: *image,
		})
		if err != nil {
			return err
		}
		return emit(res)

	case "destroy":
		fs := flag.NewFlagSet("destroy", flag.ExitOnError)
		confirm := fs.Bool("confirm", false, "actually destroy (default is a dry-run)")
		_ = fs.Parse(args)
		if fs.NArg() < 1 {
			return fmt.Errorf("usage: platformctl destroy <run_id> [--confirm]")
		}
		res, err := e.DestroyEnv(ctx, fs.Arg(0), *confirm)
		if err != nil {
			return err
		}
		return emit(res)

	default:
		usage()
		return fmt.Errorf("unknown command %q", cmd)
	}
}

// openInput returns a reader for a file path, or stdin when path is "" or "-".
func openInput(path string) (io.Reader, func(), error) {
	if path == "" || path == "-" {
		return os.Stdin, func() {}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	return f, func() { f.Close() }, nil
}

// emit prints a value as scrubbed, pretty JSON so CLI and MCP outputs match.
func emit(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(core.Scrub(string(b)))
	return nil
}

func usage() {
	fmt.Fprint(os.Stderr, strings.TrimSpace(`
platformctl - operate the ephemeral k3s platform (read is free, write is guarded)

read tools:
  list-envs
  status <run_id>
  health <run_id>
  cost <instance_type> <single|ha> <minutes>
  triage [file|-] | triage --image <ref>
  explain [logfile|-]

write tools (dry-run by default; add --confirm to mutate):
  deploy --topology single|ha --ttl <minutes> [--confirm] [--image <ref>] [--run-id <id>]
  destroy <run_id> [--confirm]
`)+"\n")
}
