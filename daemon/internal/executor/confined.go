package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/dadamsuk/slipdock/daemon/internal/egress"
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

// sandboxExec is macOS's (a variable for the tests, which build macOS's
// command line anywhere).
var sandboxExec = "/usr/bin/sandbox-exec"

func (c *confined) Ready() error {
	switch c.s.GOOS {
	case "linux":
		if abi := landlockABI(); abi < minLandlockABI {
			return fmt.Errorf("confined needs Landlock ABI %d or later (Linux 6.2, with landlock among its security modules), "+
				"which handles truncating a file; this kernel offers ABI %d", minLandlockABI, abi)
		}
		if abi := landlockABI(); c.s.Egress != nil && abi < landlockNetABI {
			return fmt.Errorf("the network allowlist under confined needs Landlock ABI %d or later (Linux 6.7), "+
				"which limits TCP connections; this kernel offers ABI %d", landlockNetABI, abi)
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

// writable is every path the job may write: its directory and what else
// it names (or, when it has Paths, only those), its scratch directory, the
// terminal devices, and the agent's state that exists.
func (c *confined) writable(p Proc) []string {
	paths := append([]string{p.Dir}, p.Writable...)
	if len(p.Paths) > 0 {
		paths = append([]string(nil), p.Paths...)
	}
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
		if c.s.Egress != nil {
			for _, port := range c.s.Egress.ports() {
				full = append(full, "--connect", strconv.Itoa(port))
			}
		}
		full = append(append(full, "--", prog), args...)
		cmd = exec.Command(c.s.Launcher, full...)
	case "darwin":
		var ports []int
		if c.s.Egress != nil {
			ports = c.s.Egress.ports()
		}
		cmd = exec.Command(sandboxExec, append([]string{"-p", SandboxProfile(w, ports...), prog}, args...)...)
	}
	cmd.Dir = p.Dir
	cmd.Env = append(append(c.environ(), p.Env...), "PWD="+p.Dir)
	if p.Scratch != "" {
		cmd.Env = append(cmd.Env, "TMPDIR="+p.Scratch)
	}
	if e := c.s.Egress; e != nil {
		// Last, so that they win over the job's own.
		cmd.Env = append(cmd.Env, egress.Env(e.addr(), shellSafe(c.launcher()))...)
	}
	mark(cmd)
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
	p.Paths, p.noState = nil, true
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

// launcher is the daemon's own binary, which git's ssh connects through
// under a network allowlist.
func (c *confined) launcher() string {
	if c.s.Launcher != "" {
		return c.s.Launcher
	}
	p, _ := os.Executable()
	return p
}

// shellSafe is path when a shell reads it as itself, else "": git's ssh
// isn't sent through the proxy then, and the sandbox stops it.
func shellSafe(path string) string {
	if path == "" || strings.IndexFunc(path, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("/._-+", r))
	}) >= 0 {
		return ""
	}
	return path
}

// SandboxProfile is macOS's sandbox profile for a confined job: anything
// but writing, which only the paths in writable (real paths) and the
// terminal devices allow. With connect (a network allowlist, #3517), no
// outbound connection either, but to those ports of localhost (the job's
// proxy first) and to unix sockets.
func SandboxProfile(writable []string, connect ...int) string {
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n")
	for _, w := range writable {
		fmt.Fprintf(&b, "  (subpath %s)\n", sbplString(w))
	}
	b.WriteString("  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")\n")
	b.WriteString("  (regex #\"^/dev/ttys[0-9]+$\") (regex #\"^/dev/fd/\"))\n")
	if len(connect) > 0 {
		b.WriteString("(deny network-outbound)\n(allow network-outbound (remote unix-socket))\n")
		for _, port := range connect {
			fmt.Fprintf(&b, "(allow network-outbound (remote ip \"localhost:%d\"))\n", port)
		}
	}
	return b.String()
}

func sbplString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}
