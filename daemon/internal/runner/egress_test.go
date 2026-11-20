package runner

import (
	"context"
	"net"
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

// A job's network allowlist (#3517), by its trust tier.

func TestATierAllowlistNeedsConfinedOrContainer(t *testing.T) {
	for _, ex := range []string{"", executor.Me, executor.User} {
		w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{Executor: ex}},
			Tiers: map[string]machine.Tier{"anyone": {Network: "allowlist"}}}
		if _, err := w.forTier(&Job{Tier: "anyone"}); err == nil || !strings.Contains(err.Error(), "needs the confined or container executor") {
			t.Errorf("executor %q: %v", ex, err)
		}
	}
	logs := &logBuf{}
	w := &Worker{Logf: logs.logf, Runner: Runner{Config: Config{Executor: executor.Confined, Network: "on"}}, GOOS: runtime.GOOS,
		Tiers: map[string]machine.Tier{
			"member": {Network: "allowlist", AllowHosts: []string{"registry.npmjs.org"}},
			"anyone": {Executor: executor.Confined, Network: "allowlist"},
		}}
	got, err := w.forTier(&Job{ID: 4, Tier: "member"})
	if err != nil {
		t.Fatal(err)
	}
	if got == w || got.Runner.Config.Network != "allowlist" || strings.Join(got.allowHosts, ",") != "registry.npmjs.org" {
		t.Fatalf("member: %+v; want a copy of its own with the allowlist", got)
	}
	if w.Runner.Config.Network != "on" || w.allowHosts != nil {
		t.Fatal("the tier changed the runner's own worker")
	}
	got.allowHosts[0] = "changed"
	if w.Tiers["member"].AllowHosts[0] != "registry.npmjs.org" {
		t.Fatal("the job's list is the ceiling's own")
	}
	if !strings.Contains(logs.String(), "job #4: trust tier member: executor confined, permission mode , network allowlist") {
		t.Fatalf("the log doesn't say the network: %s", logs.String())
	}
	// The same executor and nothing else changed is still a copy: the
	// proxy is the job's.
	w.Runner.Config.Network = "allowlist"
	if got, err := w.forTier(&Job{Tier: "anyone"}); err != nil || got == w {
		t.Fatalf("anyone: %v, %v", got == w, err)
	}
}

func TestAJobWhoseTierNeedsAnAllowlistItCantHaveIsNotRun(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"anyone": {Network: "allowlist"}}
	f := r.runJob(fakeJob{id: 130, kind: "claude", card: 7, tier: "anyone", prompt: "x"})
	if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, "needs the confined or container executor") {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatal("the agent ran with the network open")
	}
}

func TestTheJobsAllowlistIsItsAgentServerOriginAndTier(t *testing.T) {
	allowlistReady(t)
	r := newRig(t, Config{})
	gitInit(t, r.dir)
	if out, err := exec.Command("git", "-C", r.dir, "remote", "add", "origin", "ssh://github.com/me/repo.git").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	r.w.Runner.Config.Executor = executor.Confined
	w := *r.w
	w.Runner.Config.Network = "allowlist"
	w.allowHosts = []string{"registry.npmjs.org", "localhost:5432"}
	if err := os.MkdirAll(filepath.Join(w.JobsDir, "11"), 0o700); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "job.log")
	f, _ := os.Create(log)
	defer f.Close()
	j := &jobRun{job: &Job{ID: 1}, log: f, dir: r.dir}
	stop, err := w.startEgress(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if w.egress == nil || w.egress.Port == 0 || w.egress.Socket != "" {
		t.Fatalf("egress = %+v", w.egress)
	}
	if s := w.executorSettings(); s.Egress != w.egress {
		t.Fatal("the executor isn't held to the allowlist")
	}
	_, srvPort, _ := net.SplitHostPort(strings.TrimPrefix(r.srv.ts.URL, "http://"))
	if strings.Join(intsText(w.egress.Direct), ",") != srvPort+",5432" {
		t.Fatalf("the machine's own ports reached directly: %v", w.egress.Direct)
	}
	body, _ := os.ReadFile(log)
	want := "slipdock-runner: network allowlist: only api.anthropic.com:443, console.anthropic.com:443, 127.0.0.1:" + srvPort +
		", registry.npmjs.org:443, localhost:5432, github.com:22, github.com:443, api.github.com:443\n"
	if string(body) != want {
		t.Fatalf("the log says:\n%s\nwant:\n%s", body, want)
	}
	pin := filepath.Join(w.JobsDir, "11", "egress-origin")
	if b, err := os.ReadFile(pin); err != nil || string(b) != "github.com:22\n" {
		t.Fatalf("the origin isn't kept: %q %v", b, err)
	}

	// A job that rewrites the origin doesn't move a later job's allowlist.
	if out, err := exec.Command("git", "-C", r.dir, "remote", "set-url", "origin", "https://evil.example.net/x.git").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	w2 := *r.w
	w2.Runner.Config.Network = "allowlist"
	f.Truncate(0)
	f.Seek(0, 0)
	stop2, err := w2.startEgress(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	defer stop2()
	body, _ = os.ReadFile(log)
	if !strings.Contains(string(body), "the repository's origin is now evil.example.net:443, but the allowlist keeps github.com:22") ||
		strings.Contains(string(body), "only api.anthropic.com:443, console.anthropic.com:443, 127.0.0.1:"+srvPort+", evil") ||
		!strings.Contains(string(body), "github.com:22") || strings.Contains(string(body), "evil.example.net:443\n") {
		t.Fatalf("a rewritten origin:\n%s", body)
	}
	if strings.Contains(string(body), "only") && strings.Contains(string(body)[strings.Index(string(body), "only"):], "evil") {
		t.Fatalf("a rewritten origin was allowed:\n%s", body)
	}
	// A pin that isn't a host allows no origin.
	_ = os.WriteFile(pin, []byte("not a host!\n"), 0o600)
	w3 := *r.w
	w3.Runner.Config.Network = "allowlist"
	stop3, err := w3.startEgress(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	defer stop3()
	body, _ = os.ReadFile(log)
	if !strings.Contains(string(body), "isn't a host and port, so the origin isn't allowed") {
		t.Fatalf("a bad pin:\n%s", body)
	}

	w4 := *r.w
	w4.allowHosts = []string{"https://x"}
	if _, err := w4.startEgress(context.Background(), j); err == nil || !strings.Contains(err.Error(), "allow_hosts") {
		t.Fatalf("a bad host: %v", err)
	}
}

func intsText(ns []int) []string {
	var out []string
	for _, n := range ns {
		out = append(out, strconv.Itoa(n))
	}
	return out
}

// allowlistReady skips (or, on CI's executor jobs, fails) where confined
// can't hold a job to an allowlist.
func allowlistReady(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	probe, _ := executor.New(executor.Confined, executor.Settings{GOOS: runtime.GOOS, Launcher: os.Args[0],
		Egress: &executor.Egress{Port: 1}})
	if err := probe.Ready(); err != nil {
		if os.Getenv("SLIPDOCK_EXECUTOR_TESTS") == "1" {
			t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but %v", err)
		}
		t.Skip(err)
	}
}

// TestAConfinedJobUnderAnAllowlistReachesOnlyItsProxy runs a whole job:
// sandbox-exec on macOS, Landlock (ABI 4) on Linux.
func TestAConfinedJobUnderAnAllowlistReachesOnlyItsProxy(t *testing.T) {
	allowlistReady(t)
	off, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer off.Close()
	r := newRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"anyone": {Executor: executor.Confined, Network: "allowlist"}}
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c",
		`echo "proxy=$HTTPS_PROXY"; if "$0" helper dial "$OFF"; then echo "off yes"; else echo "off no"; fi`, os.Args[0]}}
	t.Setenv("OFF", off.Addr().String())
	f := r.runJob(fakeJob{id: 131, kind: "claude", card: 7, tier: "anyone", prompt: "x"})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	for _, want := range []string{"network allowlist: only api.anthropic.com:443", "proxy=http://127.0.0.1:", "off no"} {
		if !strings.Contains(f.body, want) {
			t.Errorf("no %q in the job's log:\n%s", want, f.body)
		}
	}
}
