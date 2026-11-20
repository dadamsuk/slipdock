//go:build !windows

package runner

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// Where a job's after hook runs, by its trust tier (#3518): an owner-tier
// job's as the runner says; below owner, in a container, or the job is
// refused before anything runs.

const hookImage = "ghcr.io/me/agent:2"

// hookRig is a rig on the me executor with an after hook, on a machine
// that offers a container through a fake runtime, which records its
// options and runs the program after the image. It returns the rig and
// the file the runtime's calls go to.
func hookRig(t *testing.T) (*rig, string) {
	t.Helper()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("container is Linux and macOS only")
	}
	r := newRig(t, Config{AfterHook: "report", Image: hookImage})
	r.w.Local.Hooks = map[string]machine.Command{"report": self("hook", "report")}
	bin := t.TempDir()
	calls := filepath.Join(bin, "calls")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls + "'\n" +
		"[ \"$1\" = run ] || exit 0\n" +
		"while [ $# -gt 0 ]; do a=$1; shift; [ \"$a\" = " + hookImage + " ] && exec \"$@\"; done\nexit 125\n"
	rt := filepath.Join(bin, "docker")
	if err := os.WriteFile(rt, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r.w.Offered = []string{executor.Me, executor.Container}
	r.w.Images = []string{"ghcr.io/me/*"}
	r.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	r.w.MachineDir = filepath.Join(bin, "machine")
	return r, calls
}

// runs are the runtime's `run` calls.
func runs(calls string) []string {
	b, _ := os.ReadFile(calls)
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "run ") {
			out = append(out, l)
		}
	}
	return out
}

func TestAnOwnerJobsAfterHookRunsAsTheRunnerSays(t *testing.T) {
	r, calls := hookRig(t)
	r.w.Offered = []string{executor.Me}
	f := r.runJob(fakeJob{id: 501, kind: "claude", card: 7, tier: "owner", prompt: "x"})
	if f.exit != 0 || f.status != "" {
		t.Fatalf("finish = %+v", f)
	}
	if got := r.hooksRan(); got != "report exit=0 status=done job=501\n" {
		t.Fatalf("hooks ran:\n%s", got)
	}
	if got := runs(calls); len(got) != 0 {
		t.Fatalf("an owner job's hook ran in a container: %v", got)
	}
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{AfterHook: "report"}}}
	if got, err := w.forTier(&Job{Tier: "owner"}); err != nil || got != w || got.hookContainer {
		t.Fatalf("forTier(owner) = %v, %v; want the worker itself", got, err)
	}
}

func TestABelowOwnerJobsAfterHookRunsInAContainer(t *testing.T) {
	for _, tc := range []struct {
		tier      string
		agentExit string
		want      string
	}{
		{"member", "0", "report exit=0 status=done job=502\n"},
		{"anyone", "0", "report exit=0 status=done job=502\n"},
		// No tier from the server reads as anyone.
		{"none", "0", "report exit=0 status=done job=502\n"},
		// A failed job's hook hears it, as before.
		{"member", "3", "report exit=3 status=failed job=502\n"},
	} {
		t.Run(tc.tier+"/"+tc.agentExit, func(t *testing.T) {
			r, calls := hookRig(t)
			t.Setenv("HELPER_EXIT", tc.agentExit)
			f := r.runJob(fakeJob{id: 502, kind: "claude", card: 7, tier: tc.tier, prompt: "Build it"})
			if want, _ := strconv.Atoi(tc.agentExit); f.exit != want || f.status != "" {
				t.Fatalf("finish = %+v", f)
			}
			if got := r.hooksRan(); got != tc.want {
				t.Fatalf("hooks ran:\n%s\nwant:\n%s", got, tc.want)
			}
			if !strings.Contains(f.body, "hook report ran") || !strings.Contains(f.body, "hello from the agent") {
				t.Fatalf("the job's log:\n%s", f.body)
			}
			got := runs(calls)
			if len(got) != 1 {
				t.Fatalf("want the after hook alone in a container (the agent as the runner says), got:\n%s", strings.Join(got, "\n"))
			}
			for _, want := range []string{" " + hookImage + " ", "--mount=type=bind,source=" + realPath(t, r.dir) + ",destination=" + realPath(t, r.dir),
				"--cap-drop=ALL", "--env=SLIPDOCK_EXIT"} {
				if !strings.Contains(got[0], want) {
					t.Errorf("no %q in %s", want, got[0])
				}
			}
			if strings.Contains(got[0], "Build it") {
				t.Errorf("the prompt is in the hook's command line: %s", got[0])
			}
			if !strings.Contains(r.logged.String(), "the after hook runs in a container (image "+hookImage+")") {
				t.Errorf("the daemon's log doesn't say where the hook runs:\n%s", r.logged.String())
			}
		})
	}
}

func TestABelowOwnerJobWhoseHookCantHaveAContainerIsNotRun(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(r *rig)
		want string
	}{
		{"no container offered", func(r *rig) { r.w.Offered = []string{executor.Me} },
			"a job of trust tier member runs the runner's after hook in a container, and this machine's ceiling offers no container"},
		{"no image allowed", func(r *rig) { r.w.Images = nil },
			"and the runner's image: image \"" + hookImage + "\" is refused: this machine allows no images"},
		{"no image set", func(r *rig) { r.w.Runner.Config.Image = "" },
			"and the runner's image:"},
		{"no runtime", func(r *rig) { r.w.Local.Container.Runtime = filepath.Join(t.TempDir(), "no-docker") },
			"the after hook's container:"},
		{"the container can't be made", func(r *rig) {
			r.w.newExecutor = func(name string, s executor.Settings) (executor.Executor, error) {
				if name == executor.Container {
					return nil, errors.New("no container today")
				}
				return executor.New(name, s)
			}
		}, "the after hook's container: no container today, so the job was not run"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, calls := hookRig(t)
			tc.set(r)
			f := r.runJob(fakeJob{id: 503, kind: "claude", card: 7, tier: "member", prompt: "x"})
			if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, tc.want) {
				t.Fatalf("finish = %+v\nwant %q", f, tc.want)
			}
			if r.agentSaw() != "" || r.hooksRan() != "" || len(runs(calls)) != 0 {
				t.Fatalf("something ran: agent %q, hooks %q, runtime %v", r.agentSaw(), r.hooksRan(), runs(calls))
			}
		})
	}
}

// Under an allowlist, the hook's container goes through the job's proxy,
// which runs container jobs on Linux only: elsewhere the job is refused.
func TestAHookUnderAnAllowlistNeedsLinux(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, GOOS: "darwin", Offered: []string{executor.Confined, executor.Container},
		Images: []string{"ghcr.io/me/*"},
		Runner: Runner{Config: Config{AfterHook: "report", Image: hookImage, Executor: executor.Confined}},
		Tiers:  map[string]machine.Tier{"member": {Network: machine.NetworkAllowlist}}}
	if _, err := w.forTier(&Job{Tier: "member"}); err == nil || !strings.Contains(err.Error(), "on Linux only, not darwin") {
		t.Fatalf("darwin: %v", err)
	}
	w.GOOS = "linux"
	got, err := w.forTier(&Job{Tier: "member"})
	if err != nil || !got.hookContainer || got.Runner.Config.Network != machine.NetworkAllowlist {
		t.Fatalf("linux: %+v, %v", got, err)
	}
	if w.hookContainer {
		t.Fatal("the job's limits changed the runner's own worker")
	}
}

// A job already in a container runs its hooks there; it needs no second.
func TestAContainerJobsHookStaysInItsContainer(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, Offered: []string{executor.Container}, Images: []string{"ghcr.io/me/*"},
		Runner: Runner{Config: Config{AfterHook: "report", Image: hookImage, Executor: executor.Container}}}
	got, err := w.forTier(&Job{Tier: "anyone"})
	if err != nil || got.hookContainer {
		t.Fatalf("forTier = %+v, %v", got, err)
	}
	// Nor does a runner with no after hook.
	w.Runner.Config = Config{}
	w.Offered = nil
	if got, err := w.forTier(&Job{Tier: "anyone"}); err != nil || got != w {
		t.Fatalf("no hook: %v, %v", got, err)
	}
}

// The hook's container is never swapped for the job's own executor: a
// hook whose container can't be made isn't run.
func TestAnAfterHookWithNoContainerIsNotRunOutsideIt(t *testing.T) {
	r, calls := hookRig(t)
	w := *r.w
	w.hookContainer = true
	w.newExecutor = func(name string, s executor.Settings) (executor.Executor, error) {
		if name == executor.Container {
			return nil, errors.New("gone")
		}
		return executor.New(name, s)
	}
	w.Executor, w.executorErr, w.Exec = nil, nil, nil
	w.defaults()
	log := filepath.Join(t.TempDir(), "job.log")
	f, err := os.Create(log)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	report := r.w.Local.Hooks["report"]
	j := &jobRun{job: &Job{ID: 504}, log: f, dir: r.dir, after: &report}
	w.afterHook(context.Background(), j, 0, "done")
	if r.hooksRan() != "" || len(runs(calls)) != 0 {
		t.Fatalf("the hook ran: %q %v", r.hooksRan(), runs(calls))
	}
	if b, _ := os.ReadFile(log); !strings.Contains(string(b), "slipdock-runner: the after hook was not run: its container: gone") {
		t.Fatalf("the job's log:\n%s", b)
	}
}

// The hook's container is made like a container job's: the daemon's own
// directory is never mounted, and under an allowlist it is held to the
// job's proxy, on a socket of its own.
func TestAHookContainersSettingsKeepTheMachineAndTheAllowlist(t *testing.T) {
	r, _ := hookRig(t)
	if runtime.GOOS != "linux" {
		t.Skip("the allowlist runs container jobs on Linux")
	}
	tmp := privateTemp(t)
	fake := &fakeContainer{}
	me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Fatal(err)
	}
	fake.Executor = me
	w := *r.w
	w.newExecutor = fake.make
	w.Runner.Config.Executor = executor.Confined
	w.Runner.Config.Network = machine.NetworkAllowlist
	w.hookContainer = true
	log, _ := os.Create(filepath.Join(t.TempDir(), "job.log"))
	defer log.Close()
	stop, err := w.startEgress(context.Background(), &jobRun{job: &Job{ID: 505}, log: log, dir: r.dir})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if w.egress == nil || w.egress.Port == 0 || !strings.HasPrefix(w.egress.Socket, tmp) {
		t.Fatalf("egress = %+v; want a port for the job and a socket for its hook", w.egress)
	}
	if w.Executor.Name() != executor.Confined {
		t.Fatalf("the job's executor is %s", w.Executor.Name())
	}
	ex, err := w.hookExecutor()
	if err != nil || ex != fake {
		t.Fatalf("hookExecutor = %v, %v", ex, err)
	}
	s := fake.settings[len(fake.settings)-1]
	if s.Egress != w.egress || s.Image != hookImage || !contains(s.Protected, w.MachineDir) {
		t.Fatalf("the hook's container: egress %+v, image %q, protected %v", s.Egress, s.Image, s.Protected)
	}
	// Made once a job.
	if again, _ := w.hookExecutor(); again != ex || len(fake.settings) != 1 {
		t.Fatalf("made %d times", len(fake.settings))
	}
}

// realRuntime is Docker or Podman where one runs here, else the test is
// skipped.
func realRuntime(t *testing.T) string {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skip("the real-runtime tests run on Linux")
	}
	for _, n := range []string{"docker", "podman"} {
		if p, err := exec.LookPath(n); err == nil && exec.Command(p, "info").Run() == nil {
			return p
		}
	}
	t.Skip("no Docker or Podman that runs here")
	return ""
}

// TestABelowOwnerHookInARealContainer: under Docker or Podman (skipped
// elsewhere), a member job's after hook can't read the machine's key, and
// under an allowlist can't reach a host off it.
func TestABelowOwnerHookInARealContainer(t *testing.T) {
	rt := realRuntime(t)
	image := os.Getenv("SLIPDOCK_CONTAINER_TEST_IMAGE")
	if image == "" {
		image = "alpine:3"
	}
	r := newRig(t, Config{AfterHook: "report", Image: image})
	r.w.GOOS = "linux"
	r.w.Offered = []string{executor.Me, executor.Confined, executor.Container}
	r.w.Images = []string{image}
	r.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	r.w.MachineDir = filepath.Join(t.TempDir(), "machine")
	if err := os.MkdirAll(r.w.MachineDir, 0o700); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(r.w.MachineDir, "machine.json")
	if err := os.WriteFile(key, []byte(`{"key":"sdm_machine_secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	r.w.Local.Hooks = map[string]machine.Command{"report": {Path: "/bin/sh", Args: []string{"-c",
		`cat '` + key + `' 2>/dev/null || echo "hook: no key"; ` +
			`if wget -q -T 5 -O- http://off.example.com/ >/dev/null 2>&1; then echo "hook: off yes"; else echo "hook: off no"; fi`}}}

	t.Run("the machine's key", func(t *testing.T) {
		f := r.runJob(fakeJob{id: 506, kind: "claude", card: 7, tier: "member", prompt: "x"})
		if f.exit != 0 || !strings.Contains(f.body, "hook: no key") || strings.Contains(f.body, "sdm_machine_secret") {
			t.Fatalf("finish = %+v", f)
		}
	})

	t.Run("a host off the allowlist", func(t *testing.T) {
		allowlistReady(t)
		// The hook's container runs the daemon's own binary, statically
		// linked, for the proxy; so does the confined agent.
		r.w.Launcher = staticRunner(t)
		r.w.Tiers = map[string]machine.Tier{"member": {Executor: executor.Confined, Network: machine.NetworkAllowlist}}
		f := r.runJob(fakeJob{id: 507, kind: "claude", card: 7, tier: "member", prompt: "x"})
		if f.exit != 0 || !strings.Contains(f.body, "hook: off no") || !strings.Contains(f.body, "hook: no key") ||
			!strings.Contains(f.body, "refused a connection to off.example.com:80") {
			t.Fatalf("finish = %+v", f)
		}
	})
}

// staticRunner builds slipdock-runner statically, as the releases are.
func staticRunner(t *testing.T) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "slipdock-runner")
	cmd := exec.Command("go", "build", "-o", out, "../../cmd/slipdock-runner")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v: %s", err, b)
	}
	return out
}

// The hook's program is the image's: a name the machine's PATH doesn't
// have is found in the container, not refused on the machine.
func TestAHookInAContainerIsTheImagesProgram(t *testing.T) {
	r, calls := hookRig(t)
	r.w.Local.Hooks = map[string]machine.Command{"report": {Path: "only-in-the-image"}}
	f := r.runJob(fakeJob{id: 508, kind: "claude", card: 7, tier: "member", prompt: "x"})
	if f.exit != 0 || !strings.Contains(f.body, "hello from the agent") {
		t.Fatalf("finish = %+v", f)
	}
	got := runs(calls)
	if len(got) != 1 || !strings.HasSuffix(got[0], " "+hookImage+" only-in-the-image") {
		t.Fatalf("the hook's container ran: %v", got)
	}
}

// A job already in a container (a verify job's, made one after its tier)
// runs its hook there, not in a second.
func TestAJobInAContainerMakesNoSecondForItsHook(t *testing.T) {
	r, _ := hookRig(t)
	fake := &fakeContainer{}
	w := *r.w
	w.newExecutor = fake.make
	w.Runner.Config.Executor = executor.Container
	w.hookContainer = true
	w.Executor, w.executorErr, w.Exec = nil, nil, nil
	w.defaults()
	ex, err := w.hookExecutor()
	if err != nil || ex != w.Executor || len(fake.settings) != 1 {
		t.Fatalf("hookExecutor = %v, %v; made %d", ex, err, len(fake.settings))
	}
}
