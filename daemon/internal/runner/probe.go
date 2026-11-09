package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// ProbeKind is the probe's job kind (#2580, W-2544 §8): the runner checks
// its own setup, with no card and no agent run.
const ProbeKind = "probe"

// probeStepTimeout bounds each built-in check: a program that hangs on
// --version fails its check rather than holding the probe.
var probeStepTimeout = 30 * time.Second

// probeCheck is one built-in check: its name, and what it found (nil is a
// pass, said by ok).
type probeCheck struct {
	name string
	run  func(ctx context.Context) (ok string, err error)
}

// runProbe runs a probe, watched like any job (heartbeats carry its log,
// cancel and the timeout stop it): the built-in checks, each a line in the
// log, then the runner's probe hook if its config names one, from the
// machine's own file. Every check runs, so one red line doesn't hide the
// next; the probe is green (exit 0) only when all pass, else red (1).
func (w *Worker) runProbe(ctx context.Context, j *jobRun) {
	j.env = w.jobEnv(j)
	pctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan int, 1)
	go func() { done <- w.probe(pctx, j) }()
	stop := func() {
		cancel()
		select {
		case rc := <-done:
			done <- rc
		case <-time.After(w.Grace):
		}
	}
	ended, rc := w.watch(ctx, j, done, stop, nil)
	w.end(ctx, j, ended, rc, "", nil)
}

// probe runs the checks and the hook, and answers the exit code.
func (w *Worker) probe(ctx context.Context, j *jobRun) int {
	c := w.Runner.Config
	j.note(fmt.Sprintf("probe of runner %s (#%d): %s in %s, runs as %s", w.Runner.Name, w.Runner.ID, c.Agent, c.Directory, c.Executor))
	var failed []string
	for _, check := range w.probeChecks(j) {
		if ctx.Err() != nil {
			return 130
		}
		cctx, cancel := context.WithTimeout(ctx, probeStepTimeout)
		said, err := check.run(cctx)
		cancel()
		if err != nil {
			failed = append(failed, check.name)
			j.note(fmt.Sprintf("FAIL %s: %v", check.name, err))
		} else {
			j.note(fmt.Sprintf("ok   %s: %s", check.name, said))
		}
	}
	if name := c.ProbeHook; name != "" {
		if err := w.probeHook(ctx, j, name); err != nil {
			failed = append(failed, "probe hook")
			j.note(fmt.Sprintf("FAIL probe hook %q: %v", name, err))
		} else {
			j.note(fmt.Sprintf("ok   probe hook %q: exit 0", name))
		}
	} else {
		j.note("ok   probe hook: none set")
	}
	if ctx.Err() != nil {
		return 130
	}
	if len(failed) > 0 {
		j.note(fmt.Sprintf("probe: red: %d failed (%s)", len(failed), strings.Join(failed, ", ")))
		return 1
	}
	j.note("probe: green: every check passed")
	return 0
}

// probeChecks are the built-in checks, in the order they run.
func (w *Worker) probeChecks(j *jobRun) []probeCheck {
	c := w.Runner.Config
	return []probeCheck{
		{"directory", func(ctx context.Context) (string, error) { return w.probeDirectory(ctx, c.Directory) }},
		{"agent", func(ctx context.Context) (string, error) { return w.probeAgent(ctx, c) }},
		{"gh", func(ctx context.Context) (string, error) { return w.probeGH(ctx, c.Directory) }},
		{"skills and CLI", func(context.Context) (string, error) { return probeDrift(j.job.Prompt) }},
		{"executor", func(ctx context.Context) (string, error) { return w.probeExecutor(ctx, c) }},
	}
}

// probeDirectory: the runner's directory is a git work tree with an
// origin, the repository its jobs work in. Nothing on the server names the
// repository a runner should be in, so its origin is said, for the owner
// to read.
func (w *Worker) probeDirectory(ctx context.Context, dir string) (string, error) {
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return "", fmt.Errorf("%s is not there", dir)
	}
	if _, err := w.Exec(ctx, dir, "git", "rev-parse", "--is-inside-work-tree"); err != nil {
		return "", fmt.Errorf("%s is not a git repository", dir)
	}
	origin, err := w.Exec(ctx, dir, "git", "remote", "get-url", "origin")
	if err != nil || strings.TrimSpace(origin) == "" {
		return "", fmt.Errorf("%s has no origin remote", dir)
	}
	return fmt.Sprintf("%s is a git repository, origin %s", dir, scrubURL(strings.TrimSpace(origin))), nil
}

// probeAgent: the agent's program, from the local file, answers --version.
func (w *Worker) probeAgent(ctx context.Context, c Config) (string, error) {
	agent, ok := w.Local.Agent(c.Agent)
	if !ok {
		return "", fmt.Errorf("agent %q is not defined in this machine's %s", c.Agent, machine.LocalFile)
	}
	path, err := w.resolve(agent.Path)
	if err != nil {
		return "", fmt.Errorf("%s is not on the PATH of the account jobs run as", agent.Path)
	}
	said, err := w.Exec(ctx, c.Directory, path, append(append([]string(nil), agent.Args...), "--version")...)
	if err != nil {
		return "", fmt.Errorf("%s --version failed: %s", agent.Path, orNothing(oneLine(said), err))
	}
	return fmt.Sprintf("%s --version: %s", agent.Path, firstLine(said)), nil
}

// probeGH: gh is installed and signed in, as pull requests and the merge
// kind need.
func (w *Worker) probeGH(ctx context.Context, dir string) (string, error) {
	if _, err := w.LookPath("gh"); err != nil {
		return "", errors.New("gh is not on the PATH (install the GitHub CLI)")
	}
	if said, err := w.Exec(ctx, dir, "gh", "auth", "status"); err != nil {
		return "", fmt.Errorf("gh is not signed in (run gh auth login): %s", orNothing(oneLine(said), err))
	}
	return "gh is signed in", nil
}

// probeDrift reads the server's verdict on the skills and CLI this
// runner's claim reported, from the probe's prompt ("skills: current",
// "cli: old"): the daemon can't know what the server serves.
func probeDrift(prompt string) (string, error) {
	states := map[string]string{}
	for _, line := range strings.Split(prompt, "\n") {
		if name, value, ok := strings.Cut(line, ":"); ok {
			states[strings.TrimSpace(name)] = strings.TrimSpace(value)
		}
	}
	var bad []string
	for _, name := range []string{"skills", "cli"} {
		switch v := states[name]; {
		case v == "" || v == "unknown":
			// The server couldn't tell: nothing to hold against the runner.
		case v == "current":
		case v == "none":
			bad = append(bad, name+" not installed")
		default:
			bad = append(bad, name+" "+v)
		}
	}
	said := fmt.Sprintf("skills %s, cli %s", orUnknown(states["skills"]), orUnknown(states["cli"]))
	if len(bad) > 0 {
		return "", fmt.Errorf("%s (install the server's: docs/agents.md §Install the skills)", strings.Join(bad, "; "))
	}
	return said, nil
}

// probeExecutor: the runner's executor is one this daemon offers, and a
// command runs under it in the runner's directory.
func (w *Worker) probeExecutor(ctx context.Context, c Config) (string, error) {
	if !contains(executors, c.Executor) {
		return "", fmt.Errorf("executor %q is not available on this daemon (only %s)", c.Executor, strings.Join(executors, ", "))
	}
	shell, args := "sh", []string{"-c", "echo ok"}
	if runtime.GOOS == "windows" {
		shell, args = "cmd", []string{"/c", "echo ok"}
	}
	said, err := w.Exec(ctx, c.Directory, shell, args...)
	if err != nil || strings.TrimSpace(said) != "ok" {
		return "", fmt.Errorf("a command didn't run as %s in %s: %s", c.Executor, c.Directory, orNothing(oneLine(said), err))
	}
	return fmt.Sprintf("a command runs as %s in %s", c.Executor, c.Directory), nil
}

// probeHook runs the runner's probe hook, from the machine's own file, its
// output in the probe's log. A name the file doesn't define fails it.
func (w *Worker) probeHook(ctx context.Context, j *jobRun, name string) error {
	hook, ok := w.Local.Hook(name)
	if !ok {
		return fmt.Errorf("not defined in this machine's %s", machine.LocalFile)
	}
	path, err := w.resolve(hook.Path)
	if err != nil {
		return fmt.Errorf("%s is not on the PATH", hook.Path)
	}
	hook.Path = path
	j.note(fmt.Sprintf("probe hook %q: running", name))
	if rc := w.hook(ctx, j, hook, j.env); rc != 0 {
		return fmt.Errorf("exit %d", rc)
	}
	return nil
}

// scrubURL takes the credentials out of a remote URL before it is logged.
func scrubURL(u string) string {
	if scheme, rest, ok := strings.Cut(u, "://"); ok {
		if at := strings.LastIndex(rest, "@"); at >= 0 && at < strings.Index(rest+"/", "/") {
			rest = rest[at+1:]
		}
		return scheme + "://" + rest
	}
	return u
}

func orNothing(said string, err error) string {
	if said != "" {
		return said
	}
	return err.Error()
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}
