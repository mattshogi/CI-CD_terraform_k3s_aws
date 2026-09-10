package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Command is a single external process invocation. Name is the logical command
// (an executable resolved on PATH, or a repo-relative script path containing a
// slash). Both adapters build the same Command values, so humans and agents
// drive identical processes.
type Command struct {
	Name string
	Args []string
	Env  []string // extra KEY=VALUE pairs appended to the process environment
	Dir  string   // working directory; empty means the runner's BaseDir
}

// Result captures a finished command.
type Result struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Runner executes commands. Production uses ExecRunner; tests use a mock so no
// cloud call ever happens in CI.
type Runner interface {
	Run(ctx context.Context, cmd Command) (Result, error)
}

// ExecRunner runs real processes. A Name containing a slash is resolved
// relative to BaseDir so repo scripts work regardless of the child's CWD.
type ExecRunner struct {
	BaseDir string
}

// Run executes cmd and returns its captured output.
func (r ExecRunner) Run(ctx context.Context, cmd Command) (Result, error) {
	name := cmd.Name
	if strings.Contains(name, "/") {
		name = filepath.Join(r.BaseDir, cmd.Name)
	}
	c := exec.CommandContext(ctx, name, cmd.Args...)
	if cmd.Dir != "" {
		c.Dir = cmd.Dir
	} else {
		c.Dir = r.BaseDir
	}
	c.Env = os.Environ()
	if len(cmd.Env) > 0 {
		c.Env = append(c.Env, cmd.Env...)
	}
	var out, errb bytes.Buffer
	c.Stdout = &out
	c.Stderr = &errb
	err := c.Run()
	res := Result{Stdout: out.String(), Stderr: errb.String()}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			res.ExitCode = ee.ExitCode()
			return res, fmt.Errorf("%s exited %d", cmd.Name, res.ExitCode)
		}
		return res, err
	}
	return res, nil
}
