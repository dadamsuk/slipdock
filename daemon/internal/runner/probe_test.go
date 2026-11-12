package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// fakeProbe answers the daemon's own commands a probe runs as the account
// jobs run as (the executor's Exec): git in a repository with an origin,
// and gh signed in; each can be made to fail. The agent's --version and
// the executor's command run for real, as a job's agent does.
type fakeProbe struct {
	noRepo, noOrigin, ghSignedOut bool
	ran                           []string
}

func (f *fakeProbe) exec(_ context.Context, dir, name string, args ...string) (string, error) {
	line := name + " " + strings.Join(args, " ")
	f.ran = append(f.ran, line)
	switch {
	case line == "git rev-parse --is-inside-work-tree":
		if f.noRepo {
			return "fatal: not a git repository", errors.New("exit 128")
		}
		return "true\n", nil
	case line == "git remote get-url origin":
		if f.noOrigin {
			return "error: No such remote 'origin'", errors.New("exit 2")
		}
		return "https://x-access-token:secret@example.com/acme/widgets.git\n", nil
	case line == "gh auth status":
		if f.ghSignedOut {
			return "You are not logged into any GitHub hosts.", errors.New("exit 1")
		}
		return "Logged in", nil
	}
	return "", errors.New("unexpected: " + line)
}

const greenPrompt = "probe of runner builder (#11)\nskills: current\ncli: current\n"

// probeRig is a rig whose runner has a probe hook and gh on its PATH, with
// the probe's programs faked.
func probeRig(t *testing.T) (*rig, *fakeProbe) {
	t.Helper()
	r := newRig(t, Config{ProbeHook: "check"})
	f := &fakeProbe{}
	r.w.Exec = f.exec
	r.w.LookPath = probeLookPath
	r.w.Local.Hooks = map[string]machine.Command{"check": self("hook", "probe")}
	return r, f
}

// probeLookPath finds gh (faked) and the shell (real).
func probeLookPath(name string) (string, error) {
	switch name {
	case "gh":
		return "/usr/bin/gh", nil
	case "sh", "cmd":
		return exec.LookPath(name)
	}
	return "", fmt.Errorf("%s: not found", name)
}

func TestAGreenProbe(t *testing.T) {
	r, _ := probeRig(t)
	agent := self("agent").Path
	fin := r.runJob(fakeJob{id: 300, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 0 || fin.status != "" {
		t.Fatalf("finish = %+v", fin)
	}
	for _, want := range []string{
		"ok   directory: " + r.dir + " is a git repository, origin https://example.com/acme/widgets.git",
		"ok   agent: " + agent + " --version: 2.1.0 (Claude Code)",
		"ok   gh: gh is signed in",
		"ok   skills and CLI: skills current, cli current",
		"ok   executor: a command runs as ",
		" (executor me) in " + r.dir + " and can write it",
		`probe hook "check": running`,
		"hook probe ran",
		`ok   probe hook "check": exit 0`,
		"probe: green: every check passed",
	} {
		if !strings.Contains(fin.body, want) {
			t.Errorf("the log has no %q:\n%s", want, fin.body)
		}
	}
	if strings.Contains(fin.body, "secret") {
		t.Errorf("the origin's credentials are in the log:\n%s", fin.body)
	}
	if left, _ := filepath.Glob(filepath.Join(r.dir, ".slipdock-probe*")); len(left) > 0 {
		t.Errorf("the executor check left its file behind: %v", left)
	}
	if !strings.Contains(r.hooksRan(), "probe exit= status= job=300") {
		t.Errorf("hooks ran: %q", r.hooksRan())
	}
	if r.agentSaw() != "" {
		t.Error("a probe runs no agent job")
	}
	if kinds := r.srv.header(11).Get("X-Runner-Kinds"); !strings.HasSuffix(kinds, ",probe") {
		t.Errorf("X-Runner-Kinds = %q", kinds)
	}
}

func TestNoProbeHookSetIsNoFailure(t *testing.T) {
	r, _ := probeRig(t)
	r.w.Runner.Config.ProbeHook = ""
	fin := r.runJob(fakeJob{id: 301, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 0 || !strings.Contains(fin.body, "ok   probe hook: none set") {
		t.Fatalf("finish = %+v", fin)
	}
	if r.hooksRan() != "" {
		t.Errorf("a hook ran: %q", r.hooksRan())
	}
}

func TestARedProbeSaysEachFailureAndRunsTheRest(t *testing.T) {
	cases := []struct {
		name   string
		set    func(*rig, *fakeProbe)
		prompt string
		want   string
	}{
		{"not a repository", func(_ *rig, f *fakeProbe) { f.noRepo = true }, "", "FAIL directory: "},
		{"no origin", func(_ *rig, f *fakeProbe) { f.noOrigin = true }, "", "has no origin remote"},
		{"agent undefined", func(r *rig, _ *fakeProbe) { r.w.Runner.Config.Agent = "lint" }, "", `FAIL agent: agent "lint" is not defined`},
		{"agent not on the path", func(r *rig, _ *fakeProbe) {
			r.w.Local.Agents["claude"] = machine.Command{Path: "claude-nowhere"}
		}, "", "FAIL agent: claude-nowhere is not on the PATH"},
		{"version fails", func(r *rig, _ *fakeProbe) {
			r.t.Setenv("HELPER_VERSION", "Error: no login")
			r.t.Setenv("HELPER_VERSION_EXIT", "1")
		}, "", "--version failed: Error: no login"},
		{"no gh", func(r *rig, _ *fakeProbe) {
			r.w.LookPath = func(n string) (string, error) {
				if n == "gh" {
					return "", errors.New("not found")
				}
				return probeLookPath(n)
			}
		}, "", "FAIL gh: gh is not on the PATH"},
		{"gh signed out", func(_ *rig, f *fakeProbe) { f.ghSignedOut = true }, "", "FAIL gh: gh is not signed in"},
		{"skills drifted", nil, "skills: drifted (slipdock-loop)\ncli: current\n", "FAIL skills and CLI: skills drifted (slipdock-loop)"},
		{"cli old", nil, "skills: current\ncli: old\n", "FAIL skills and CLI: cli old"},
		{"cli none", nil, "skills: current\ncli: none\n", "FAIL skills and CLI: cli not installed"},
		{"executor not offered", func(r *rig, _ *fakeProbe) { r.w.Runner.Config.Executor = "container" }, "", "FAIL executor: executor \"container\": " + containerRefusal()},
		{"no shell", func(r *rig, _ *fakeProbe) {
			r.w.LookPath = func(n string) (string, error) {
				if n == "sh" || n == "cmd" {
					return "", errors.New("not found")
				}
				return probeLookPath(n)
			}
		}, "", "FAIL executor: " + shellName() + " is not on the PATH of the account jobs run as"},
		{"hook undefined", func(r *rig, _ *fakeProbe) { r.w.Runner.Config.ProbeHook = "nothere" }, "", `FAIL probe hook "nothere": not defined in this machine's`},
		{"hook fails", func(_ *rig, _ *fakeProbe) { t.Setenv("HELPER_HOOK_EXIT_probe", "3") }, "", `FAIL probe hook "check": exit 3`},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, f := probeRig(t)
			if c.set != nil {
				c.set(r, f)
			}
			prompt := c.prompt
			if prompt == "" {
				prompt = greenPrompt
			}
			fin := r.runJob(fakeJob{id: int64(310 + i), kind: ProbeKind, prompt: prompt})
			if fin.exit != 1 {
				t.Fatalf("exit %d, want 1:\n%s", fin.exit, fin.body)
			}
			if !strings.Contains(fin.body, c.want) || !strings.Contains(fin.body, "probe: red: 1 failed") {
				t.Fatalf("the log has no %q, or more than one failure:\n%s", c.want, fin.body)
			}
			// One red check doesn't stop the others.
			if !strings.Contains(fin.body, "skills and CLI:") || !strings.Contains(fin.body, "probe hook") {
				t.Fatalf("a check was skipped:\n%s", fin.body)
			}
		})
	}
}

func TestAProbeWhoseExecutorCantRunSkipsWhatRunsUnderIt(t *testing.T) {
	cases := []struct {
		name  string
		setup func(r *rig)
		want  string
	}{
		{"not one this daemon runs", func(r *rig) { r.w.Runner.Config.Executor = executor.Container },
			"FAIL executor: executor \"container\": " + containerRefusal()},
		{"built but not ready", func(r *rig) {
			r.w.Runner.Config.Executor = executor.Confined
			r.w.GOOS = "linux"
			r.w.Launcher = filepath.Join(t.TempDir(), "gone")
		}, `FAIL executor: executor "confined": `},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, f := probeRig(t)
			c.setup(r)
			fin := r.runJob(fakeJob{id: int64(340 + i), kind: ProbeKind, prompt: greenPrompt})
			if fin.exit != 1 || !strings.Contains(fin.body, c.want) || !strings.Contains(fin.body, "probe: red: 1 failed (executor)") {
				t.Fatalf("exit %d, want 1 with %q and only the executor failed:\n%s", fin.exit, c.want, fin.body)
			}
			for _, skipped := range []string{"skip directory: not checked", "skip agent: not checked", "skip gh: not checked", `skip probe hook "check": not checked`} {
				if !strings.Contains(fin.body, skipped) {
					t.Fatalf("no %q:\n%s", skipped, fin.body)
				}
			}
			if len(f.ran) != 0 || r.hooksRan() != "" {
				t.Fatalf("commands %q and hooks %q ran under an executor that can't run them", f.ran, r.hooksRan())
			}
			if !strings.Contains(fin.body, "ok   skills and CLI:") {
				t.Fatalf("the check that needs no executor didn't run:\n%s", fin.body)
			}
		})
	}
}

func TestAProbeWhoseDirectoryIsGone(t *testing.T) {
	r, _ := probeRig(t)
	_ = os.RemoveAll(r.dir)
	fin := r.runJob(fakeJob{id: 330, kind: ProbeKind, prompt: greenPrompt})
	// The agent, the executor's command and the hook run in the directory
	// too, so they fail with it.
	if fin.exit != 1 || !strings.Contains(fin.body, "FAIL directory: "+r.dir+" is not there, as the account jobs run as sees it") ||
		!strings.Contains(fin.body, "probe: red: 4 failed (directory, agent, executor, probe hook)") {
		t.Fatalf("finish = %+v", fin)
	}
}

func TestAProbesLogStreamsAndCancelStopsItsHook(t *testing.T) {
	r, _ := probeRig(t)
	tick := t.TempDir() + "/tick"
	t.Setenv("HELPER_TICK", tick)
	r.w.Local.Hooks["check"] = self("tree")
	r.srv.add(fakeJob{runner: 11, id: 320, kind: ProbeKind, prompt: greenPrompt})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.w.Run(ctx)
	waitFor(t, "the hook's child to tick", func() bool { _, err := os.Stat(tick); return err == nil })
	// The checks so far and the hook's output reach the board as it runs.
	waitFor(t, "a heartbeat with the probe's log", func() bool {
		r.srv.mu.Lock()
		defer r.srv.mu.Unlock()
		b := r.srv.beats[320]
		return len(b) > 0 && strings.Contains(b[len(b)-1], "ok   gh: gh is signed in") &&
			strings.Contains(b[len(b)-1], "started the tree")
	})
	r.srv.mu.Lock()
	r.srv.cancel[320] = true
	r.srv.mu.Unlock()
	waitFor(t, "the finish", func() bool { _, ok := r.srv.finish(320); return ok })
	f, _ := r.srv.finish(320)
	if f.exit != 130 || f.status != "cancelled" {
		t.Fatalf("finish = %+v", f)
	}
	if ticking(t, tick) {
		t.Fatal("the probe hook's child outlived the cancel")
	}
}

func TestProbeDriftReadsTheServersVerdict(t *testing.T) {
	if said, err := probeDrift("probe\nskills: unknown\n"); err != nil || said != "skills unknown, cli unknown" {
		t.Fatalf("unknown = %q, %v", said, err)
	}
	if _, err := probeDrift("skills: none\ncli: old\n"); err == nil ||
		!strings.Contains(err.Error(), "skills not installed; cli old") {
		t.Fatalf("err = %v", err)
	}
	// A CLI the server serves unsigned isn't the machine's to fix (#2825).
	if said, err := probeDrift("skills: current\ncli: unsigned on server\n"); err != nil ||
		said != "skills current, cli unsigned on server" {
		t.Fatalf("unsigned = %q, %v", said, err)
	}
	// Nor are skills the server serves unsigned, named as it names them (#2916).
	if said, err := probeDrift("skills: unsigned on server (slipdock-loop)\ncli: current\n"); err != nil ||
		said != "skills unsigned on server (slipdock-loop), cli current" {
		t.Fatalf("skills unsigned = %q, %v", said, err)
	}
	// Both at once pass; drifted skills beside an unsigned CLI still fail.
	if _, err := probeDrift("skills: unsigned on server (slipdock)\ncli: unsigned on server\n"); err != nil {
		t.Fatalf("both unsigned: %v", err)
	}
	if _, err := probeDrift("skills: drifted (slipdock)\ncli: unsigned on server\n"); err == nil ||
		!strings.Contains(err.Error(), "skills drifted (slipdock)") {
		t.Fatalf("drifted beside unsigned: %v", err)
	}
}

func TestScrubURLDropsCredentials(t *testing.T) {
	for in, want := range map[string]string{
		"https://x-access-token:abc@example.com/acme/widgets.git": "https://example.com/acme/widgets.git",
		"https://github.com/acme/widgets.git":                     "https://github.com/acme/widgets.git",
		"ssh://git@example.com/acme/widgets.git":                  "ssh://example.com/acme/widgets.git",
		"/srv/git/widgets.git":                                    "/srv/git/widgets.git",
	} {
		if got := scrubURL(in); got != want {
			t.Errorf("scrubURL(%q) = %q, want %q", in, got, want)
		}
	}
}

// shellName is the shell the executor check runs.
func shellName() string {
	if runtime.GOOS == "windows" {
		return "cmd"
	}
	return "sh"
}

// containerRefusal is why a container runner with no image can't run: on
// Windows, that there is no container executor there at all.
func containerRefusal() string {
	if runtime.GOOS == "windows" {
		return "container is Linux and macOS only"
	}
	return "no image is named"
}

// probeExecutor is the me executor with the daemon's own commands faked
// (git and gh, by f) and gh on its PATH.
type probeExecutor struct {
	executor.Executor
	f *fakeProbe
}

func (p probeExecutor) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	return p.f.exec(ctx, dir, name, args...)
}

func (p probeExecutor) Resolve(prog string) (string, error) {
	if prog == "gh" {
		return "/usr/bin/gh", nil
	}
	return p.Executor.Resolve(prog)
}

func TestEveryProbeCheckGoesThroughTheExecutor(t *testing.T) {
	r, f := probeRig(t)
	r.w.Runner.Config.ProbeHook = ""
	r.w.Exec = nil // the worker's default: the executor's Exec
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	rec := &recorder{Executor: probeExecutor{me, f}, home: t.TempDir()}
	r.w.Executor = rec
	saw := filepath.Join(t.TempDir(), "version.out")
	t.Setenv("HELPER_VERSION_OUT", saw)

	fin := r.runJob(fakeJob{id: 350, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 0 {
		t.Fatalf("finish = %+v", fin)
	}
	agent := filepath.Base(self("agent").Path)
	shell := "command sh -c "
	if runtime.GOOS == "windows" {
		shell = "command cmd.exe /c "
	}
	for _, want := range []string{
		"isdir",
		"exec git rev-parse --is-inside-work-tree",
		"exec git remote get-url origin",
		"resolve " + agent,
		"command " + agent + " helper agent --version",
		"resolve gh",
		"exec gh auth status",
		"resolve " + shellName(),
		shell,
	} {
		if !rec.saw(want) {
			t.Errorf("the probe didn't ask the executor for %q: %v", want, rec.calls)
		}
	}
	// The agent's --version ran as a job's agent does: in the job's
	// directory, with the job's variables.
	data, err := os.ReadFile(saw)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); !strings.Contains(got, "dir="+realPath(t, r.dir)+"\n") || !strings.Contains(got, "env=SLIPDOCK_JOB_ID=350\n") ||
		!strings.Contains(got, "env=SLIPDOCK_JOB_KIND=probe\n") {
		t.Fatalf("the agent's --version ran with %q", got)
	}
}

// refusing is an executor that won't run a job's command: it can't make
// it (err), or what it makes is refused (sudo asking for a password).
type refusing struct {
	executor.Executor
	err error
}

func (r refusing) Command(p executor.Proc, prog string, args ...string) (*exec.Cmd, error) {
	if r.err != nil {
		return nil, r.err
	}
	h := self("refuse")
	return r.Executor.Command(p, h.Path, h.Args...)
}

func TestAProbeWhoseExecutorRefusesTheCommand(t *testing.T) {
	for i, refuse := range []error{nil, errors.New("sudo: a password is required")} {
		t.Run(fmt.Sprintf("made=%v", refuse == nil), func(t *testing.T) {
			r, _ := probeRig(t)
			r.w.Runner.Config.ProbeHook = ""
			me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS, LookPath: probeLookPath})
			r.w.Executor = refusing{me, refuse}
			fin := r.runJob(fakeJob{id: int64(360 + i), kind: ProbeKind, prompt: greenPrompt})
			for _, want := range []string{
				"--version failed: sudo: a password is required",
				"FAIL executor: a command didn't run as me in " + r.dir + ": sudo: a password is required",
				"probe: red: 2 failed (agent, executor)",
			} {
				if fin.exit != 1 || !strings.Contains(fin.body, want) {
					t.Fatalf("exit %d, want 1 and %q:\n%s", fin.exit, want, fin.body)
				}
			}
		})
	}
}

func TestAProbeInADirectoryTheAccountCantWrite(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a read-only directory is a POSIX mode here")
	}
	if os.Geteuid() == 0 {
		t.Skip("root writes a read-only directory")
	}
	r, _ := probeRig(t)
	if err := os.Chmod(r.dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(r.dir, 0o755) })
	fin := r.runJob(fakeJob{id: 370, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 1 || !strings.Contains(fin.body, " (executor me) in "+r.dir+" but can't write it: ") ||
		!strings.Contains(fin.body, "probe: red: 1 failed (executor)") {
		t.Fatalf("exit %d, want 1 with the executor unable to write:\n%s", fin.exit, fin.body)
	}
}

// unwriting is an executor whose shell runs and exits 0 but never says
// writable: the executor check must not take the exit for the write.
type unwriting struct {
	executor.Executor
}

func (u unwriting) Command(p executor.Proc, prog string, args ...string) (*exec.Cmd, error) {
	if strings.TrimSuffix(filepath.Base(prog), ".exe") == shellName() {
		h := self("ran-unwritten")
		return u.Executor.Command(p, h.Path, h.Args...)
	}
	return u.Executor.Command(p, prog, args...)
}

func TestAProbeWhoseCommandExitsZeroWithoutWriting(t *testing.T) {
	r, f := probeRig(t)
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS, LookPath: probeLookPath})
	r.w.Executor = unwriting{probeExecutor{me, f}}
	fin := r.runJob(fakeJob{id: 375, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 1 || !strings.Contains(fin.body, "a command runs as someone (executor me) in "+r.dir+" but can't write it: ") ||
		!strings.Contains(fin.body, "probe: red: 1 failed (executor)") {
		t.Fatalf("exit %d, want 1 with the command never saying writable:\n%s", fin.exit, fin.body)
	}
}

// TestARealConfinedProbeIsGreen: a confined runner's probe, nothing faked
// but gh's login, is green: its git, agent and command run confined, and
// the command can write the directory. Required where CI says so
// (SLIPDOCK_EXECUTOR_TESTS=1: Linux and macOS).
func TestARealConfinedProbeIsGreen(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	ready, _ := executor.New(executor.Confined, executor.Settings{GOOS: runtime.GOOS, Launcher: os.Args[0]})
	if err := ready.Ready(); err != nil {
		if os.Getenv("SLIPDOCK_EXECUTOR_TESTS") == "1" {
			t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but %v", err)
		}
		t.Skip(err)
	}
	r := newRig(t, Config{})
	r.w.Runner.Config.Executor = executor.Confined
	gitInit(t, r.dir)
	if out, err := exec.Command("git", "-C", r.dir, "remote", "add", "origin", "https://example.com/acme/widgets.git").CombinedOutput(); err != nil {
		t.Fatalf("git remote add: %v %s", err, out)
	}
	// gh, signed in: a stand-in on the PATH.
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte("#!/bin/sh\necho Logged in\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	r.w.LookPath = exec.LookPath
	// The agent's --version writes into the job's scratch directory: only
	// a confined job's TMPDIR lets it.
	scratch := filepath.Join(r.w.JobsDir, "11", "tmp")
	t.Setenv("HELPER_VERSION_OUT", filepath.Join(scratch, "version.out"))

	fin := r.runJob(fakeJob{id: 380, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 0 {
		t.Fatalf("finish = %+v", fin)
	}
	for _, want := range []string{
		"ok   directory: " + r.dir + " is a git repository, origin https://example.com/acme/widgets.git",
		"ok   agent: " + self("agent").Path + " --version: 2.1.0 (Claude Code)",
		"ok   gh: gh is signed in",
		" (executor confined) in " + r.dir + " and can write it",
		"probe: green: every check passed",
	} {
		if !strings.Contains(fin.body, want) {
			t.Errorf("the log has no %q:\n%s", want, fin.body)
		}
	}
	data, err := os.ReadFile(filepath.Join(scratch, "version.out"))
	if err != nil || !strings.Contains(string(data), "tmp="+scratch+"\n") {
		t.Fatalf("the agent's --version didn't run with the job's scratch directory: %q %v", data, err)
	}
}
