package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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
	if w.executorReady() == nil {
		// The confined job's TMPDIR, as a job's agent has it.
		if err := w.newScratch(j); err != nil {
			failed = append(failed, "scratch")
			j.note(fmt.Sprintf("FAIL scratch: can't make the job's temporary directory: %v", err))
		}
	}
	for _, check := range w.probeChecks(j) {
		if ctx.Err() != nil {
			return 130
		}
		cctx, cancel := context.WithTimeout(ctx, probeStepTimeout)
		said, err := check.run(cctx)
		cancel()
		switch {
		case isSkipped(err):
			j.note(fmt.Sprintf("skip %s: %v", check.name, err))
		case err != nil:
			failed = append(failed, check.name)
			j.note(fmt.Sprintf("FAIL %s: %v", check.name, err))
		default:
			j.note(fmt.Sprintf("ok   %s: %s", check.name, said))
		}
	}
	if name := c.ProbeHook; name != "" {
		if err := w.probeHook(ctx, j, name); isSkipped(err) {
			j.note(fmt.Sprintf("skip probe hook %q: %v", name, err))
		} else if err != nil {
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

// probeChecks are the built-in checks, in the order they run. Each runs
// as a job would (#2619): the directory is looked at, and git and gh run,
// as the account jobs run as (the executor's IsDir and Exec), and the
// agent's --version and the executor's own command run as a job's agent
// does (asJob).
func (w *Worker) probeChecks(j *jobRun) []probeCheck {
	c := w.Runner.Config
	return []probeCheck{
		{"directory", w.needsExecutor(func(ctx context.Context) (string, error) { return w.probeDirectory(ctx, c.Directory) })},
		{"agent", w.needsExecutor(func(ctx context.Context) (string, error) { return w.probeAgent(ctx, j, c) })},
		{"gh", w.needsExecutor(func(ctx context.Context) (string, error) { return w.probeGH(ctx, c.Directory) })},
		{"skills and CLI", func(context.Context) (string, error) { return probeDrift(j.job.Prompt) }},
		{"executor", func(ctx context.Context) (string, error) { return w.probeExecutor(ctx, j, c) }},
	}
}

// probeDirectory: the runner's directory is a git work tree with an
// origin, the repository its jobs work in, as the account jobs run as sees
// it. Nothing on the server names the repository a runner should be in, so
// its origin is said, for the owner to read.
func (w *Worker) probeDirectory(ctx context.Context, dir string) (string, error) {
	if !w.Executor.IsDir(dir) {
		return "", fmt.Errorf("%s is not there, as the account jobs run as sees it", dir)
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

// probeAgent: the agent's program, from the local file, answers --version,
// run as the job's agent would be.
func (w *Worker) probeAgent(ctx context.Context, j *jobRun, c Config) (string, error) {
	agent, ok := w.Local.Agent(c.Agent)
	if !ok {
		return "", fmt.Errorf("agent %q is not defined in this machine's %s", c.Agent, machine.LocalFile)
	}
	path, err := w.Executor.Resolve(agent.Path)
	if err != nil {
		return "", fmt.Errorf("%s is not on the PATH of the account jobs run as", agent.Path)
	}
	said, err := w.asJob(ctx, j, path, append(append([]string(nil), agent.Args...), "--version")...)
	if err != nil {
		return "", fmt.Errorf("%s --version failed: %s", agent.Path, orNothing(oneLine(said), err))
	}
	return fmt.Sprintf("%s --version: %s", agent.Path, firstLine(said)), nil
}

// probeGH: gh is installed and signed in, as pull requests and the merge
// kind need.
func (w *Worker) probeGH(ctx context.Context, dir string) (string, error) {
	if _, err := w.Executor.Resolve("gh"); err != nil {
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
		case strings.HasPrefix(v, "unsigned"):
			// The server's CLI (#2825) or skills (#2916) differ but aren't
			// signed (a deploy from main): the machine can't take them, so
			// it isn't the machine's to fix.
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

// probeExecutor: the runner's executor is one this daemon can run and is
// ready (a dedicated account set up, Landlock there), and a command runs
// under it as a job's agent does, in the runner's directory, and can write
// there: what a job has to do.
func (w *Worker) probeExecutor(ctx context.Context, j *jobRun, c Config) (string, error) {
	if err := w.executorReady(); err != nil {
		return "", err
	}
	shell, args := "sh", []string{"-c", "echo ran; id -un; f=.slipdock-probe.$$; : > \"$f\" && rm -f \"$f\" && echo writable"}
	if runtime.GOOS == "windows" {
		shell, args = "cmd", []string{"/c", "echo ran&& echo %USERNAME%&& type nul > .slipdock-probe&& del .slipdock-probe&& echo writable"}
	}
	path, err := w.Executor.Resolve(shell)
	if err != nil {
		return "", fmt.Errorf("%s is not on the PATH of the account jobs run as", shell)
	}
	said, err := w.asJob(ctx, j, path, args...)
	lines := strings.Split(strings.ReplaceAll(said, "\r", ""), "\n")
	if len(lines) < 2 || strings.TrimSpace(lines[0]) != "ran" {
		return "", fmt.Errorf("a command didn't run as %s in %s: %s", c.Executor, c.Directory, orNothing(oneLine(said), err))
	}
	account := strings.TrimSpace(lines[1])
	rest := strings.TrimSpace(strings.Join(lines[2:], "\n"))
	if err != nil || !strings.HasSuffix(rest, "writable") {
		return "", fmt.Errorf("a command runs as %s (executor %s) in %s but can't write it: %s",
			account, c.Executor, c.Directory, orNothing(oneLine(rest), orErr(err)))
	}
	return fmt.Sprintf("a command runs as %s (executor %s) in %s and can write it", account, c.Executor, c.Directory), nil
}

// asJob runs prog as the job's agent would run (the executor's Command,
// with the job's directory, variables and, confined, scratch directory),
// not as the daemon's own git: what it printed, and an error if it didn't
// exit 0. It is stopped, through the executor, when ctx ends.
func (w *Worker) asJob(ctx context.Context, j *jobRun, prog string, args ...string) (string, error) {
	cmd, err := w.Executor.Command(w.proc(j, j.env), prog, args...)
	if err != nil {
		return "", err
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		return "", err
	}
	done := make(chan int, 1)
	go func() { done <- exitCode(cmd, cmd.Wait()) }()
	var rc int
	select {
	case rc = <-done:
	case <-ctx.Done():
		w.stopWith(w.Executor, cmd, done)
		return out.String(), ctx.Err()
	}
	if rc != 0 {
		return out.String(), fmt.Errorf("exit %d", rc)
	}
	return out.String(), nil
}

// probeHook runs the runner's probe hook, from the machine's own file, its
// output in the probe's log. A name the file doesn't define fails it.
func (w *Worker) probeHook(ctx context.Context, j *jobRun, name string) error {
	if err := w.executorSkip(); err != nil {
		return err
	}
	hook, ok := w.Local.Hook(name)
	if !ok {
		return fmt.Errorf("not defined in this machine's %s", machine.LocalFile)
	}
	path, err := w.Executor.Resolve(hook.Path)
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

// orErr is err, or that nothing was said.
func orErr(err error) error {
	if err == nil {
		return errors.New("the write failed and said nothing")
	}
	return err
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// executorReady says why no job can run under the runner's executor now,
// or nil.
func (w *Worker) executorReady() error {
	if w.executorErr != nil {
		return fmt.Errorf("executor %q: %v", w.Runner.Config.Executor, w.executorErr)
	}
	if err := w.Executor.Ready(); err != nil {
		return fmt.Errorf("executor %q: %v", w.Runner.Config.Executor, err)
	}
	return nil
}

// errSkipped is a check that can't be made: its failure is another's
// (the executor's), said once there rather than again in each.
type errSkipped struct{ why string }

func (e errSkipped) Error() string { return e.why }

func isSkipped(err error) bool {
	var skip errSkipped
	return errors.As(err, &skip)
}

// needsExecutor is a check run only when the runner's executor is ready:
// every check but the executor's runs as the account jobs run as, and with
// no such account it is skipped, the executor check saying why once.
func (w *Worker) needsExecutor(check func(context.Context) (string, error)) func(context.Context) (string, error) {
	return func(ctx context.Context) (string, error) {
		if err := w.executorSkip(); err != nil {
			return "", err
		}
		return check(ctx)
	}
}

// executorSkip is the skip of a check that needs the executor, or nil when
// it is ready.
func (w *Worker) executorSkip() error {
	if w.executorReady() != nil {
		return errSkipped{fmt.Sprintf("not checked: executor %q can't run jobs", w.Runner.Config.Executor)}
	}
	return nil
}
