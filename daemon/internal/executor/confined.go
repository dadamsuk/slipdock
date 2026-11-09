package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// confined runs a job as the daemon's account, unable to write outside its
// working directory, its scratch directory, the terminal devices and the
// agent's own state.
//
// The daemon's own git and gh for the runner (its worktrees, the merge)
// and the runner's hooks run confined too, able to write only the
// runner's repository and its worktrees. A job can write the repository,
// .git/config and .git/hooks included, so whatever git runs from there
// next (core.fsmonitor, a hook, a filter, a diff driver, an ssh command,
// a credential helper, an include…) is the job's code. Git has too many
// such keys, and adds more, for a list of -c overrides to be sure of
// them all; the sandbox bounds every one.
type confined struct {
	*local
	mu  sync.Mutex
	top string // the runner's repository, once found
}

func (c *confined) Name() string { return Confined }

// sandboxExec is macOS's.
const sandboxExec = "/usr/bin/sandbox-exec"

func (c *confined) Ready() error {
	switch c.s.GOOS {
	case "linux":
		if abi := landlockABI(); abi < minLandlockABI {
			return fmt.Errorf("confined needs Landlock ABI %d or later (Linux 6.2, with landlock among its security modules), "+
				"which handles truncating a file; this kernel offers ABI %d", minLandlockABI, abi)
		}
		if c.s.Launcher == "" {
			return errors.New("confined needs the slipdock-runner binary to launch the job, and the daemon can't find its own")
		}
		if _, err := os.Stat(c.s.Launcher); err != nil {
			return fmt.Errorf("confined launches the job through %s: %v", c.s.Launcher, err)
		}
		return nil
	case "darwin":
		if _, err := os.Stat(sandboxExec); err != nil {
			return fmt.Errorf("confined needs %s: %v", sandboxExec, err)
		}
		return nil
	}
	return Supported(Confined, c.s.GOOS)
}

// writable is every path the job may write: its directory, what else it
// names, its scratch directory, the terminal devices, and the agent's
// state that exists.
func (c *confined) writable(p Proc) []string {
	paths := append([]string{p.Dir}, p.Writable...)
	if p.Scratch != "" {
		paths = append(paths, p.Scratch)
	}
	for _, w := range c.s.Writable {
		if _, err := os.Lstat(w); err == nil && !p.noState {
			paths = append(paths, w)
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, path := range paths {
		if path == "" {
			continue
		}
		if real, err := filepath.EvalSymlinks(path); err == nil {
			path = real
		}
		path = filepath.Clean(path)
		if !seen[path] {
			seen[path] = true
			out = append(out, path)
		}
	}
	return out
}

func (c *confined) Command(p Proc, prog string, args ...string) (*exec.Cmd, error) {
	if err := c.Ready(); err != nil {
		return nil, err
	}
	var cmd *exec.Cmd
	w := c.writable(p)
	switch c.s.GOOS {
	case "linux":
		full := []string{"confine"}
		for _, path := range w {
			full = append(full, "--write", path)
		}
		full = append(append(full, "--", prog), args...)
		cmd = exec.Command(c.s.Launcher, full...)
	case "darwin":
		cmd = exec.Command(sandboxExec, append([]string{"-p", SandboxProfile(w), prog}, args...)...)
	}
	cmd.Dir = p.Dir
	cmd.Env = append(append(c.environ(), p.Env...), "PWD="+p.Dir)
	if p.Scratch != "" {
		cmd.Env = append(cmd.Env, "TMPDIR="+p.Scratch)
	}
	inGroup(cmd)
	return cmd, nil
}

// repository is what the daemon's own work for the runner may write: the
// runner's directory, its repository and the repository's worktrees
// (<repo>-lanes, made here so that it can be named).
func (c *confined) repository(ctx context.Context) []string {
	paths := []string{c.s.Repo}
	c.mu.Lock()
	top := c.top
	c.mu.Unlock()
	if top == "" && c.s.Repo != "" {
		// Only reads, confined to the runner's directory.
		out, err := c.run(ctx, Proc{Dir: c.s.Repo, noState: true}, "git", "rev-parse", "--show-toplevel")
		if t := strings.TrimSpace(out); err == nil && filepath.IsAbs(t) {
			top = filepath.Clean(t)
			c.mu.Lock()
			c.top = top
			c.mu.Unlock()
		}
	}
	if top != "" {
		lanes := top + "-lanes"
		_ = os.MkdirAll(lanes, 0o755)
		paths = append(paths, top, lanes)
	}
	return paths
}

// Exec runs the daemon's own git or gh confined to the runner's repository.
func (c *confined) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	return c.run(ctx, Proc{Dir: dir, Writable: c.repository(ctx), noState: true}, name, args...)
}

// Hook is a runner's hook, confined to the repository and the job's
// scratch directory: it runs where the job could have planted git config.
func (c *confined) Hook(ctx context.Context, p Proc, prog string, args ...string) (*exec.Cmd, error) {
	p.Writable = append(append([]string(nil), p.Writable...), c.repository(ctx)...)
	p.noState = true
	return c.Command(p, prog, args...)
}

func (c *confined) run(ctx context.Context, p Proc, name string, args ...string) (string, error) {
	cmd, err := c.Command(p, name, args...)
	if err != nil {
		return "", err
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		return "", err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-ctx.Done():
		c.Stop(cmd, true)
		<-done
		err = ctx.Err()
	}
	return out.String(), err
}

// devices a confined job may still write: the null and terminal devices.
var devices = []string{"/dev/null", "/dev/zero", "/dev/full", "/dev/tty", "/dev/ptmx", "/dev/pts"}

// SandboxProfile is macOS's sandbox profile for a confined job: anything
// but writing, which only the paths in writable (real paths) and the
// terminal devices allow.
func SandboxProfile(writable []string) string {
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n")
	for _, w := range writable {
		fmt.Fprintf(&b, "  (subpath %s)\n", sbplString(w))
	}
	b.WriteString("  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")\n")
	b.WriteString("  (regex #\"^/dev/ttys[0-9]+$\") (regex #\"^/dev/fd/\"))\n")
	return b.String()
}

func sbplString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}
