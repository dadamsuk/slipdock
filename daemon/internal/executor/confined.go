package executor

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// confined runs a job as the daemon's account, unable to write outside its
// working directory, its scratch directory, the terminal devices and the
// agent's own state. The daemon's own git and gh work (worktrees, the
// merge) is not the job's, and runs as under me.
type confined struct{ *local }

func (c *confined) Name() string { return Confined }

// sandboxExec is macOS's.
const sandboxExec = "/usr/bin/sandbox-exec"

func (c *confined) Ready() error {
	switch c.s.GOOS {
	case "linux":
		if abi := landlockABI(); abi < 1 {
			return errors.New("confined needs Landlock, which this kernel doesn't offer (Linux 5.13 or later, with landlock among its security modules)")
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
		if _, err := os.Lstat(w); err == nil {
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
