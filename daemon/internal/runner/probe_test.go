package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// fakeProbe answers the programs a probe runs: git in a repository with an
// origin, the agent's --version, gh signed in and the shell; each can be
// made to fail.
type fakeProbe struct {
	noRepo, noOrigin, versionFails, ghSignedOut, shellFails bool
	agent                                                   string // the agent's path, as resolved
	ran                                                     []string
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
	case name == f.agent && len(args) > 0 && args[len(args)-1] == "--version":
		if f.versionFails {
			return "Error: no login", errors.New("exit 1")
		}
		return "2.1.0 (Claude Code)\nmore\n", nil
	case line == "gh auth status":
		if f.ghSignedOut {
			return "You are not logged into any GitHub hosts.", errors.New("exit 1")
		}
		return "Logged in", nil
	case name == "sh" || name == "cmd":
		if f.shellFails {
			return "", errors.New("exec: permission denied")
		}
		return "ok\n", nil
	}
	return "", errors.New("unexpected: " + line)
}

const greenPrompt = "probe of runner builder (#11)\nskills: current\ncli: current\n"

// probeRig is a rig whose runner has a probe hook and gh on its PATH, with
// the probe's programs faked.
func probeRig(t *testing.T) (*rig, *fakeProbe) {
	t.Helper()
	r := newRig(t, Config{ProbeHook: "check"})
	f := &fakeProbe{agent: self("agent").Path}
	r.w.Exec = f.exec
	r.w.LookPath = func(name string) (string, error) {
		if name == "gh" {
			return "/usr/bin/gh", nil
		}
		return "", fmt.Errorf("%s: not found", name)
	}
	r.w.Local.Hooks = map[string]machine.Command{"check": self("hook", "probe")}
	return r, f
}

func TestAGreenProbe(t *testing.T) {
	r, f := probeRig(t)
	fin := r.runJob(fakeJob{id: 300, kind: ProbeKind, prompt: greenPrompt})
	if fin.exit != 0 || fin.status != "" {
		t.Fatalf("finish = %+v", fin)
	}
	for _, want := range []string{
		"ok   directory: " + r.dir + " is a git repository, origin https://example.com/acme/widgets.git",
		"ok   agent: " + f.agent + " --version: 2.1.0 (Claude Code)",
		"ok   gh: gh is signed in",
		"ok   skills and CLI: skills current, cli current",
		"ok   executor: a command runs as me in " + r.dir,
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
		{"version fails", func(_ *rig, f *fakeProbe) { f.versionFails = true }, "", "--version failed: Error: no login"},
		{"no gh", func(r *rig, _ *fakeProbe) {
			r.w.LookPath = func(n string) (string, error) { return "", errors.New("not found") }
		}, "", "FAIL gh: gh is not on the PATH"},
		{"gh signed out", func(_ *rig, f *fakeProbe) { f.ghSignedOut = true }, "", "FAIL gh: gh is not signed in"},
		{"skills drifted", nil, "skills: drifted (slipdock-loop)\ncli: current\n", "FAIL skills and CLI: skills drifted (slipdock-loop)"},
		{"cli old", nil, "skills: current\ncli: old\n", "FAIL skills and CLI: cli old"},
		{"cli none", nil, "skills: current\ncli: none\n", "FAIL skills and CLI: cli not installed"},
		{"executor not offered", func(r *rig, _ *fakeProbe) { r.w.Runner.Config.Executor = "container" }, "", `FAIL executor: executor "container": container is not available`},
		{"shell fails", func(_ *rig, f *fakeProbe) { f.shellFails = true }, "", "FAIL executor: a command didn't run as me"},
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
			`FAIL executor: executor "container": container is not available`},
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
	// The hook runs in the directory too, so it fails with it.
	if fin.exit != 1 || !strings.Contains(fin.body, "FAIL directory: "+r.dir+" is not there") ||
		!strings.Contains(fin.body, "probe: red: 2 failed (directory, probe hook)") {
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
