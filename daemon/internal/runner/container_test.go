package runner

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestAContainerRunnersImageMustBeOnTheMachinesAllowList(t *testing.T) {
	root := filepath.Join(t.TempDir(), "src")
	defer func(g string) { goos = g }(goos)
	goos = "linux"
	runner := func(image, network string) Runner {
		return Runner{ID: 1, BoardID: 3, Config: Config{Agent: "claude", Directory: filepath.Join(root, "repo"),
			PermissionMode: "default", TimeoutMinutes: 60, Executor: "container", Image: image, Network: network}}
	}
	allowing := func(images ...string) machine.Ceiling {
		c := ceiling(root)
		c.Executors = []string{"me", "container"}
		c.ContainerImages = images
		return c
	}
	for _, c := range []struct {
		name    string
		r       Runner
		ceiling machine.Ceiling
		want    string // "" for inside
	}{
		{"on the list", runner("ghcr.io/me/agent:2", "off"), allowing("ghcr.io/me/agent:*"), ""},
		{"on the list, network unset", runner("ghcr.io/me/agent:2", ""), allowing("ghcr.io/me/agent:*"), ""},
		{"not on the list", runner("docker.io/someone/agent:2", "on"), allowing("ghcr.io/me/agent:*"),
			`image "docker.io/someone/agent:2" is not on this machine's allow-list (container_images in its ceiling: ghcr.io/me/agent:*)`},
		{"no list at all", runner("ghcr.io/me/agent:2", "on"), allowing(), "this machine allows no images"},
		{"no image", runner("", "on"), allowing("ghcr.io/me/agent:*"), "no image is named"},
		{"an option for an image", runner("--privileged", "on"), allowing("ghcr.io/me/agent:*"), "is not an image name"},
		{"a network that is neither", runner("ghcr.io/me/agent:2", "Off"), allowing("ghcr.io/me/agent:*"), `network "Off" is not on or off`},
		{"container not offered", runner("ghcr.io/me/agent:2", "on"), func() machine.Ceiling {
			c := allowing("ghcr.io/me/agent:*")
			c.Executors = []string{"me"}
			return c
		}(), `executor "container" is not one this machine offers`},
	} {
		err := c.r.Check(c.ceiling)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: refused: %v", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}
	// An image other than a container runner's isn't checked.
	other := runner("--privileged", "")
	other.Config.Executor = "me"
	if err := other.Check(allowing()); err != nil {
		t.Errorf("a me runner's image: %v", err)
	}

	// Build refuses it, and gives the workers the machine's list.
	mc := &MachineConfig{Runners: []Runner{runner("ghcr.io/me/agent:2", "off"), func() Runner {
		r := runner("evil.example.com/agent:1", "on")
		r.ID = 2
		return r
	}()}}
	workers, refused := Build(mc, allowing("ghcr.io/me/agent:*"), Worker{})
	if len(workers) != 1 || workers[0].Runner.ID != 1 || refused[2] == nil || !strings.Contains(refused[2].Error(), "allow-list") {
		t.Fatalf("workers %v, refused %v", workers, refused)
	}
	if strings.Join(workers[0].Images, ",") != "ghcr.io/me/agent:*" {
		t.Fatalf("the worker's allow-list: %v", workers[0].Images)
	}
}

func TestAContainerWorkersExecutorIsTheRunnersAndTheMachines(t *testing.T) {
	r := newRig(t, Config{})
	c := &r.w.Runner.Config
	c.Executor, c.Image, c.Network = executor.Container, "ghcr.io/me/agent:2", "off"
	r.w.Images = []string{"ghcr.io/me/agent:*"}
	r.w.Local.Container = &machine.ContainerSettings{Runtime: "podman", Pull: "missing", Login: []string{"/h/.x"}, Env: []string{"GOFLAGS"}}
	bin := t.TempDir()
	r.w.LookPath = func(name string) (string, error) { return filepath.Join(bin, name), nil }
	s := r.w.executorSettings()
	if s.Image != "ghcr.io/me/agent:2" || strings.Join(s.Images, ",") != "ghcr.io/me/agent:*" || !s.NetworkOff ||
		s.Runtime != "podman" || s.Pull != "missing" || s.Login[0] != "/h/.x" || s.PassEnv[0] != "GOFLAGS" ||
		s.Agent != "claude" || s.CLI != filepath.Join(bin, "slipdock") || s.Repo != r.dir {
		t.Fatalf("settings %+v", s)
	}
	if !oneOfAll(s.Protected, filepath.Dir(r.w.JobsDir), r.w.JobsDir) {
		t.Fatalf("the daemon's own directory isn't protected: %v", s.Protected)
	}
	c.Network = "on"
	if r.w.executorSettings().NetworkOff {
		t.Fatal("network on is on")
	}
	// The local file's CLI wins.
	r.w.Local.CLI = filepath.Join(bin, "my-slipdock")
	if s := r.w.executorSettings(); s.CLI != r.w.Local.CLI {
		t.Fatal(s.CLI)
	}
}

func oneOfAll(list []string, want ...string) bool {
	for _, w := range want {
		if !contains(list, w) {
			return false
		}
	}
	return true
}

// TestAContainerJobRunsThroughTheRuntime runs a job under a fake runtime
// that records its options and runs the program after the image.
func TestAContainerJobRunsThroughTheRuntime(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("container is Linux and macOS only")
	}
	r := newRig(t, Config{BeforeHook: "setup"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup")}
	bin := t.TempDir()
	calls := filepath.Join(bin, "calls")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls + "'\n" +
		"[ \"$1\" = run ] || exit 0\n" +
		"while [ $# -gt 0 ]; do a=$1; shift; [ \"$a\" = ghcr.io/me/agent:2 ] && exec \"$@\"; done\nexit 125\n"
	rt := filepath.Join(bin, "docker")
	if err := os.WriteFile(rt, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c := &r.w.Runner.Config
	c.Executor, c.Image, c.Network = executor.Container, "ghcr.io/me/agent:2", "off"
	r.w.Images = []string{"ghcr.io/me/*"}
	r.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	// The rig's jobs are beside its repository; a daemon's directory that
	// held the repository would refuse to mount it.
	r.w.MachineDir = filepath.Join(bin, "machine")
	r.w.Getenv = func(k string) string { return map[string]string{"SLIPDOCK_TOKEN": "sdk_daemon_secret"}[k] }
	t.Setenv("SLIPDOCK_TOKEN", "sdk_daemon_secret")

	f := r.runJob(fakeJob{id: 401, kind: "claude", card: 7, prompt: "Build it"})
	if f.exit != 0 || !strings.Contains(f.body, "hello from the agent") {
		t.Fatalf("finish = %+v", f)
	}
	b, _ := os.ReadFile(calls)
	runs := []string{}
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "run ") {
			runs = append(runs, l)
		}
	}
	if len(runs) != 2 {
		t.Fatalf("want the hook and the agent run in containers, got:\n%s", b)
	}
	for _, l := range runs {
		for _, want := range []string{"--network=none", "--mount=type=bind,source=" + realPath(t, r.dir) + ",destination=" + realPath(t, r.dir),
			"--env=SLIPDOCK_JOB_ID", " ghcr.io/me/agent:2 "} {
			if !strings.Contains(l, want) {
				t.Errorf("no %q in %s", want, l)
			}
		}
		if strings.Contains(l, "SLIPDOCK_TOKEN") || strings.Contains(l, "sdk_daemon_secret") || strings.Contains(l, "Build it") &&
			strings.Index(l, "Build it") < strings.Index(l, "ghcr.io/me/agent:2") {
			t.Errorf("a secret or the prompt is among the runtime's options: %s", l)
		}
	}
	if !strings.Contains(r.hooksRan(), "setup") {
		t.Fatalf("the before hook didn't run: %q", r.hooksRan())
	}

	// The daemon's own directory holding the repository: refused.
	r3 := newRig(t, Config{})
	r3.w.Runner.Config.Executor, r3.w.Runner.Config.Image = executor.Container, "ghcr.io/me/agent:2"
	r3.w.Images = []string{"ghcr.io/me/*"}
	r3.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	f = r3.runJob(fakeJob{id: 403, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 127 || !strings.Contains(f.body, "is, holds or is inside") || r3.agentSaw() != "" {
		t.Fatalf("finish = %+v", f)
	}

	// An image taken off the list since: nothing runs.
	_ = os.Remove(calls)
	r2 := newRig(t, Config{})
	r2.w.Runner.Config.Executor, r2.w.Runner.Config.Image = executor.Container, "ghcr.io/me/agent:2"
	r2.w.Images = []string{"ghcr.io/other/*"}
	r2.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	r2.w.MachineDir = filepath.Join(bin, "machine")
	f = r2.runJob(fakeJob{id: 402, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 127 || !strings.Contains(f.body, "is not on this machine's allow-list") || r2.agentSaw() != "" {
		t.Fatalf("finish = %+v", f)
	}
	if b, _ := os.ReadFile(calls); strings.Contains(string(b), "run ") {
		t.Fatalf("the runtime ran a container:\n%s", b)
	}
}

// TestAContainerJobsTranscriptReachesTheServer (#2625): the fake runtime
// writes the agent's transcript into the directory mounted at the home's
// .claude/projects, and plants links to a file and a directory of the
// machine's that name the card too, touched last so they'd be the newest.
// Only the transcript is sent; the hook gets no such mount; and the
// directory is gone once the job ends.
func TestAContainerJobsTranscriptReachesTheServer(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("container is Linux and macOS only")
	}
	if !executor.BeneathReads {
		t.Skip("this build reads no container transcript (Go 1.24's os.Root)")
	}
	r := newRig(t, Config{BeforeHook: "setup"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup")}
	bin := t.TempDir()
	calls, txdir := filepath.Join(bin, "calls"), filepath.Join(bin, "txdir")
	hostDir := filepath.Join(bin, "host")
	secret := filepath.Join(hostDir, "secret.jsonl")
	if err := os.MkdirAll(filepath.Join(hostDir, "dir"), 0o700); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls + "'\n" +
		"[ \"$1\" = run ] || exit 0\n" +
		"for a in \"$@\"; do case \"$a\" in --mount=type=bind,source=*,destination=*/.claude/projects)\n" +
		"  s=${a#--mount=type=bind,source=}; s=${s%%,destination=*}; echo \"$s\" > '" + txdir + "'\n" +
		"  mkdir -p \"$s/proj\"\n" +
		// The planted links first, and a few of the daemon's looks with
		// nothing else there, so a reader that followed them would send
		// them; then the transcript, and the machine's files touched to be
		// the newest.
		"  printf '{\"text\":\"%s HOST_SECRET\"}\\n' \"$SLIPDOCK_CARD_URL\" > '" + secret + "'\n" +
		"  cp '" + secret + "' '" + filepath.Join(hostDir, "dir", "s.jsonl") + "'\n" +
		"  ln -s '" + secret + "' \"$s/proj/z.jsonl\"; ln -s '" + filepath.Join(hostDir, "dir") + "' \"$s/linked\"\n" +
		"  sleep 0.2\n" +
		"  printf '{\"text\":\"%s\"}\\n{\"n\":2}\\n' \"$SLIPDOCK_CARD_URL\" > \"$s/proj/s.jsonl\"\n" +
		"  sleep 0.1; touch '" + secret + "' '" + filepath.Join(hostDir, "dir", "s.jsonl") + "';;\n" +
		"esac; done\n" +
		"while [ $# -gt 0 ]; do a=$1; shift; [ \"$a\" = ghcr.io/me/agent:2 ] && exec \"$@\"; done\nexit 125\n"
	rt := filepath.Join(bin, "docker")
	if err := os.WriteFile(rt, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c := &r.w.Runner.Config
	c.Executor, c.Image, c.Network = executor.Container, "ghcr.io/me/agent:2", "off"
	r.w.Images = []string{"ghcr.io/me/*"}
	r.w.Local.Container = &machine.ContainerSettings{Runtime: rt, Pull: "missing"}
	r.w.MachineDir = filepath.Join(bin, "machine")
	// The local file's transcripts directory is the machine's, not the job's.
	r.w.Local.Transcripts = hostDir

	f := r.runJob(fakeJob{id: 404, kind: "claude", card: 7, prompt: "Build it"})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	got := r.srv.transcript[404]
	if len(got) != 2 || !strings.Contains(got[0], "/cards/7") || got[1] != `{"n":2}` {
		t.Fatalf("sent %q: want the job's own transcript", got)
	}
	for _, l := range got {
		if strings.Contains(l, "HOST_SECRET") {
			t.Fatalf("sent the machine's file: %q", got)
		}
	}

	b, _ := os.ReadFile(calls)
	var agent, hook string
	for _, l := range strings.Split(string(b), "\n") {
		switch {
		case strings.HasPrefix(l, "run ") && strings.Contains(l, " hook setup"):
			hook = l
		case strings.HasPrefix(l, "run ") && strings.Contains(l, " agent"):
			agent = l
		}
	}
	if hook == "" || agent == "" {
		t.Fatalf("want the hook and the agent run in containers, got:\n%s", b)
	}
	if strings.Contains(hook, ".claude/projects") || !strings.Contains(agent, ",destination="+filepath.Join(r.w.jobHome(), ".claude", "projects")) {
		t.Fatalf("the transcripts mount is the agent's alone:\nhook:  %s\nagent: %s", hook, agent)
	}
	dir, _ := os.ReadFile(txdir)
	if d := strings.TrimSpace(string(dir)); d == "" {
		t.Fatal("the runtime saw no transcripts directory")
	} else if _, err := os.Lstat(d); !os.IsNotExist(err) {
		t.Fatalf("%s is still there after the job: %v", d, err)
	}
	// RemoveAll took the links, never what they pointed at.
	if _, err := os.Stat(secret); err != nil {
		t.Fatalf("the machine's file went with the directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(hostDir, "dir", "s.jsonl")); err != nil {
		t.Fatalf("the machine's directory went with the job's: %v", err)
	}
}
