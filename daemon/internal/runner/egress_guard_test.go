//go:build !windows

package runner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// The job's proxy (#3517): what happens when it can't start, what it
// leaves behind, and where its origin rule comes from.

// privateTemp points the process's temporary directory at a new one of
// the test's, and returns it.
func privateTemp(t *testing.T) string {
	t.Helper()
	// Short: the proxy's unix socket goes in it.
	dir, err := os.MkdirTemp("", "eg")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("TMPDIR", dir)
	return dir
}

func leftInTemp(t *testing.T, dir string) []string {
	t.Helper()
	m, _ := filepath.Glob(filepath.Join(dir, "slipdock-egress-*"))
	return m
}

// containerEgressWorker is a worker whose job runs in a (fake) container
// under an allowlist, and a job log to read.
func containerEgressWorker(t *testing.T) (*Worker, *jobRun, string) {
	t.Helper()
	r := newRig(t, Config{})
	me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeContainer{Executor: me}
	w := *r.w
	w.newExecutor = fake.make
	w.Runner.Config.Executor = executor.Container
	w.Runner.Config.Network = machine.NetworkAllowlist
	log := filepath.Join(t.TempDir(), "job.log")
	f, err := os.Create(log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return &w, &jobRun{job: &Job{ID: 1}, log: f, dir: r.dir}, log
}

func TestAContainerJobsProxyLeavesNothingBehind(t *testing.T) {
	tmp := privateTemp(t)
	w, j, _ := containerEgressWorker(t)
	stop, err := w.startEgress(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	if w.egress == nil || !strings.HasPrefix(w.egress.Socket, tmp) {
		t.Fatalf("egress = %+v; want its socket in %s", w.egress, tmp)
	}
	if _, err := os.Stat(w.egress.Socket); err != nil {
		t.Fatalf("the proxy's socket: %v", err)
	}
	stop()
	if left := leftInTemp(t, tmp); len(left) != 0 {
		t.Fatalf("the proxy's directory outlived it: %v", left)
	}
}

func TestAProxyWithNoDirectoryRunsNoJob(t *testing.T) {
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "gone"))
	w, j, _ := containerEgressWorker(t)
	stop, err := w.startEgress(context.Background(), j)
	if err == nil {
		stop()
		t.Fatal("the proxy started with no directory for its socket")
	}
	if !strings.Contains(err.Error(), "no directory for the job's proxy") || !strings.Contains(err.Error(), "so the job was not run") {
		t.Fatalf("err = %v", err)
	}
	if w.egress != nil {
		t.Fatal("the job's executor was given a proxy that isn't there")
	}
}

func TestAProxyThatCantListenRunsNoJobAndLeavesNothing(t *testing.T) {
	// A directory whose socket path is longer than a unix socket's can be.
	tmp := filepath.Join(t.TempDir(), strings.Repeat("d", 120))
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmp)
	w, j, _ := containerEgressWorker(t)
	stop, err := w.startEgress(context.Background(), j)
	if err == nil {
		stop()
		t.Fatal("the proxy started on a socket it can't have")
	}
	if !strings.Contains(err.Error(), "the job's network allowlist didn't start") {
		t.Fatalf("err = %v", err)
	}
	if left := leftInTemp(t, tmp); len(left) != 0 {
		t.Fatalf("a proxy that didn't start left %v", left)
	}
}

// originWorker is a worker whose executor can run, with git's answer for
// the origin given.
func originWorker(t *testing.T, out string, gitErr error, calls *int) *Worker {
	t.Helper()
	me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Fatal(err)
	}
	return &Worker{Runner: Runner{ID: 11}, Executor: me, Exec: func(context.Context, string, string, ...string) (string, error) {
		*calls++
		return out, gitErr
	}}
}

func jobLog(t *testing.T) (*jobRun, func() string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "job.log")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return &jobRun{job: &Job{ID: 1}, log: f, dir: t.TempDir()}, func() string { b, _ := os.ReadFile(path); return string(b) }
}

func TestTheOriginRuleComesOnlyFromGitThatRan(t *testing.T) {
	ctx := context.Background()
	calls := 0

	// An executor that can't run reads no origin: git isn't run for it.
	j, _ := jobLog(t)
	w := originWorker(t, "https://github.com/me/repo.git\n", nil, &calls)
	w.executorErr = errors.New("no such executor")
	if r, ok := w.origin(ctx, j); ok || calls != 0 {
		t.Fatalf("origin = %v, %v, git run %d times; want none, not run", r, ok, calls)
	}

	// git that fails gives no origin, whatever it printed.
	w = originWorker(t, "https://github.com/me/repo.git\n", errors.New("exit status 2"), &calls)
	if r, ok := w.origin(ctx, j); ok {
		t.Fatalf("a failed git gave the origin %v", r)
	}

	// No jobs directory: the origin as it is, kept nowhere, and nothing said.
	j, read := jobLog(t)
	w = originWorker(t, "https://github.com/me/repo.git\n", nil, &calls)
	if r, ok := w.origin(ctx, j); !ok || r.Host != "github.com" || r.Port != 443 {
		t.Fatalf("origin = %v, %v", r, ok)
	}
	if got := read(); got != "" {
		t.Fatalf("the job's log says %q", got)
	}

	// A jobs directory the pin can't be written in: the job's log says so.
	j, read = jobLog(t)
	w = originWorker(t, "https://github.com/me/repo.git\n", nil, &calls)
	w.JobsDir = filepath.Join(t.TempDir(), "missing")
	if _, ok := w.origin(ctx, j); !ok {
		t.Fatal("the origin wasn't allowed")
	}
	if got := read(); !strings.Contains(got, "network allowlist: can't keep the origin") {
		t.Fatalf("the job's log says %q", got)
	}
}

// An agent job of an allowlist tier runs behind its proxy, which is gone
// once the job ends.
func TestAnAgentJobsProxyEndsWithTheJob(t *testing.T) {
	tmp := privateTemp(t)
	r, fake, _ := verifyRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"anyone": {Executor: executor.Container, Network: machine.NetworkAllowlist}}
	r.w.Images = []string{"ghcr.io/example/agent:*"}
	r.w.Runner.Config.Image = "ghcr.io/example/agent:1"

	f := r.runJob(fakeJob{id: 404, kind: "claude", card: 42, prompt: "Build #42"})
	if f.exit != 0 || f.status != "" {
		t.Fatalf("finish = %+v", f)
	}
	if len(fake.settings) == 0 || fake.settings[len(fake.settings)-1].Egress == nil {
		t.Fatal("the job's container isn't held to the allowlist")
	}
	if left := leftInTemp(t, tmp); len(left) != 0 {
		t.Fatalf("the job's proxy outlived it: %v", left)
	}
}

func TestATierThatSaysNothingOfTheNetworkLeavesItOn(t *testing.T) {
	logs := &logBuf{}
	w := &Worker{Logf: logs.logf, Runner: Runner{Config: Config{PermissionMode: "acceptEdits"}},
		Tiers: map[string]machine.Tier{"anyone": {MaxPermissionMode: "plan"}}}
	if _, err := w.forTier(&Job{ID: 5, Tier: "anyone"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "job #5: trust tier anyone: executor me, permission mode plan, network on") {
		t.Fatalf("the log says: %s", logs.String())
	}
}
