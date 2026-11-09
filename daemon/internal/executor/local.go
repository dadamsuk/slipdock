package executor

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
)

// local is the me executor: the daemon's own account and environment.
type local struct{ s Settings }

func (l *local) Name() string { return Me }
func (l *local) Ready() error { return nil }
func (l *local) Home() string { return l.s.Home }

func (l *local) Command(p Proc, prog string, args ...string) (*exec.Cmd, error) {
	cmd := exec.Command(prog, args...)
	cmd.Dir = p.Dir
	cmd.Env = append(append(l.environ(), p.Env...), "PWD="+p.Dir)
	inGroup(cmd)
	return cmd, nil
}

// environ is the daemon's environment without what a job is given: a
// stale SLIPDOCK_EXIT, say, from whatever started the daemon, would read
// as the job's.
func (l *local) environ() []string {
	env := os.Environ()
	if l.s.Environ != nil {
		env = l.s.Environ()
	}
	return withoutJobVars(env)
}

func (l *local) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	return run(ctx, cmd)
}

func (l *local) Stop(cmd *exec.Cmd, force bool) { signalTree(cmd, force) }

func (l *local) Resolve(prog string) (string, error) {
	if filepath.IsAbs(prog) {
		_, err := os.Stat(prog)
		return prog, err
	}
	if l.s.LookPath != nil {
		return l.s.LookPath(prog)
	}
	return exec.LookPath(prog)
}

func (l *local) IsDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func (l *local) Files() Files { return localFiles{} }
