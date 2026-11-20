package runner

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// A job's fake credentials (#3524): planted in a container job's home,
// watched for by its proxy.

// tripContainer stands in for the container executor: the me executor,
// with the proxy and the planted home a real container would give the job
// passed in as HTTPS_PROXY and TRIPWIRE_HOME.
type tripContainer struct {
	executor.Executor
	mu       sync.Mutex
	settings []executor.Settings
}

func (f *tripContainer) make(name string, s executor.Settings) (executor.Executor, error) {
	if name != executor.Container {
		return executor.New(name, s)
	}
	me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.settings = append(f.settings, s)
	f.mu.Unlock()
	return &tripExec{Executor: me, s: s}, nil
}

func (f *tripContainer) last() executor.Settings {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.settings) == 0 {
		return executor.Settings{}
	}
	return f.settings[len(f.settings)-1]
}

type tripExec struct {
	executor.Executor
	s executor.Settings
}

func (e *tripExec) Name() string { return executor.Container }

func (e *tripExec) Command(p executor.Proc, prog string, args ...string) (*exec.Cmd, error) {
	if eg := e.s.Egress; eg != nil {
		p.Env = append(append([]string(nil), p.Env...), fmt.Sprintf("HTTPS_PROXY=http://127.0.0.1:%d", eg.Port),
			"TRIPWIRE_HOME="+eg.Tripwire)
	}
	return e.Executor.Command(p, prog, args...)
}

func tripRig(t *testing.T, r *rig) *tripContainer {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the container executor runs on Linux and macOS")
	}
	fake := &tripContainer{}
	r.w.newExecutor = fake.make
	r.w.GOOS = "linux"
	r.w.Offered = []string{executor.Me, executor.Container}
	r.w.Images = []string{"ghcr.io/example/*"}
	r.w.Tiers = map[string]machine.Tier{"anyone": {Executor: executor.Container, Network: machine.NetworkAllowlist}}
	r.w.Local.Agents["claude"] = self("exfil")
	return fake
}

// tripped checks a job that sent its fake key id out: stopped (not run
// out its hour), reported failed with where it was seen, its log saying
// so, and its planted credentials gone with it.
func tripped(t *testing.T, r *rig, fake *tripContainer, f finished, took time.Duration) {
	t.Helper()
	if took > 20*time.Second {
		t.Fatalf("the job ran %s: it wasn't stopped", took)
	}
	if f.exit != 137 || f.status != "failed" {
		t.Fatalf("finish = %+v", f)
	}
	if got := f.query.Get("tripwire"); !strings.Contains(got, "the AWS access key id, in the request line") ||
		!strings.Contains(got, "evil.example.net") {
		t.Fatalf("tripwire = %q", got)
	}
	if !strings.Contains(f.body, "tripwire: the job's fake credentials were seen leaving") ||
		!strings.Contains(f.body, "its pool is paused until a person resumes it") {
		t.Fatalf("the job's log:\n%s", f.body)
	}
	if !strings.Contains(r.logged.String(), "fake credentials were seen leaving") {
		t.Fatalf("the daemon's log:\n%s", r.logged.String())
	}
	dir := fake.last().Egress.Tripwire
	if dir == "" {
		t.Fatal("the job's home had no fake credentials")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("the job's fake credentials outlived it: %v", err)
	}
}

func TestAContainerJobThatSendsItsFakeCredentialsIsStoppedAndReported(t *testing.T) {
	r := newRig(t, Config{})
	fake := tripRig(t, r)
	r.w.Runner.Config.Executor, r.w.Runner.Config.Image = executor.Container, "ghcr.io/example/agent:1"
	start := time.Now()
	f := r.runJob(fakeJob{id: 501, kind: "claude", card: 7, tier: "anyone", prompt: "x"})
	tripped(t, r, fake, f, time.Since(start))
}

func TestAVerifyJobThatSendsItsFakeCredentialsIsStoppedAndReported(t *testing.T) {
	r, _, sha := verifyRig(t, Config{})
	fake := tripRig(t, r)
	r.w.Images = []string{"ghcr.io/example/verify:*"}
	start := time.Now()
	f := r.runJob(fakeJob{id: 502, kind: "verify", card: 42, prompt: "Check #42", token: testJobToken, sha: sha})
	tripped(t, r, fake, f, time.Since(start))
}

func TestAContainerJobsPlantedCredentialsAreItsOwn(t *testing.T) {
	r := newRig(t, Config{})
	fake := tripRig(t, r)
	r.w.Runner.Config.Executor, r.w.Runner.Config.Image = executor.Container, "ghcr.io/example/agent:1"
	var seen []string
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c",
		`cat "$TRIPWIRE_HOME/.aws/credentials" "$TRIPWIRE_HOME/.config/gh/hosts.yml"`}}
	for _, id := range []int64{503, 504} {
		f := r.runJob(fakeJob{id: id, kind: "claude", card: 7, tier: "anyone", prompt: "x"})
		if f.exit != 0 || f.query.Get("tripwire") != "" {
			t.Fatalf("a job that sent nothing: %+v", f)
		}
		if !strings.Contains(f.body, "aws_access_key_id = AKIA") || !strings.Contains(f.body, "oauth_token: ghp_") {
			t.Fatalf("job #%d's home:\n%s", id, f.body)
		}
		seen = append(seen, f.body)
		if dir := fake.last().Egress.Tripwire; dir == "" || filepath.Dir(dir) == r.w.Home {
			t.Fatalf("planted in %q", dir)
		}
	}
	if seen[0] == seen[1] {
		t.Fatal("two jobs had the same fake credentials")
	}
}

func TestAJobWhoseHomeIsTheMachinesGetsNoFakeCredentials(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{Executor: executor.Confined, Network: "allowlist"}},
		GOOS: runtime.GOOS, Client: &Client{Server: "https://slipdock.example.com"}}
	log, _ := os.Create(filepath.Join(t.TempDir(), "job.log"))
	defer log.Close()
	stop, err := w.startEgress(t.Context(), &jobRun{job: &Job{ID: 1}, log: log, dir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if w.egress == nil || w.egress.Tripwire != "" {
		t.Fatalf("a confined job's egress: %+v", w.egress)
	}
}

func TestATripAfterTheAgentEndedStillFailsTheJob(t *testing.T) {
	r := newRig(t, Config{})
	log, _ := os.Create(filepath.Join(t.TempDir(), "job.log"))
	defer log.Close()
	j := &jobRun{job: &Job{ID: 505}, log: log}
	j.trip("the GitHub token, in a header, going to x.example.net")
	j.trip("a second one")
	r.srv.add(fakeJob{id: 505, runner: r.w.Runner.ID})
	r.w.defaults()
	r.w.report(t.Context(), j.job, j, 0, "", "", "", nil)
	f, ok := r.srv.finish(505)
	if !ok || f.status != "failed" || f.query.Get("tripwire") != "the GitHub token, in a header, going to x.example.net" {
		t.Fatalf("finish = %+v", f)
	}
}
