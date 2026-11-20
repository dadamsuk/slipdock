package runner

import (
	"context"
	"net/http"
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

// A verify job (#3522) runs in a container, in its own clone, with its own
// token and its agent's login alone.

const testJobToken = "jobtoken_abcdefghijklmnopqrstuvwxyz0123"

// fakeContainer stands in for the container executor: the me executor,
// named container, keeping the settings it was made with and the
// commit the agent's directory is at when it starts.
type fakeContainer struct {
	executor.Executor
	mu       sync.Mutex
	settings []executor.Settings
	head     string
	commands []string
}

func (f *fakeContainer) make(name string, s executor.Settings) (executor.Executor, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if name != executor.Container {
		return executor.New(name, s)
	}
	f.settings = append(f.settings, s)
	return f, nil
}

func (f *fakeContainer) Name() string { return executor.Container }

func (f *fakeContainer) Command(p executor.Proc, prog string, args ...string) (*exec.Cmd, error) {
	out, _ := exec.Command("git", "-C", p.Dir, "rev-parse", "HEAD").Output()
	f.mu.Lock()
	f.head = strings.TrimSpace(string(out))
	f.commands = append(f.commands, filepath.Base(prog)+" "+strings.Join(args, " "))
	f.mu.Unlock()
	return f.Executor.Command(p, prog, args...)
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=a@example.com", "-c", "user.name=a"}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// verifyRig is a rig whose machine can run a container (a fake one), whose
// runner's repository has an origin with a branch card-1 one commit ahead
// of main. It returns the rig, the fake and card-1's commit.
func verifyRig(t *testing.T, cfg Config) (*rig, *fakeContainer, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the container executor runs on Linux and macOS")
	}
	r := newRig(t, cfg)
	origin := filepath.Join(t.TempDir(), "origin.git")
	git(t, filepath.Dir(origin), "init", "-q", "--bare", origin)
	gitInit(t, r.dir)
	git(t, r.dir, "remote", "add", "origin", origin)
	git(t, r.dir, "push", "-q", "origin", "HEAD:main")
	git(t, r.dir, "checkout", "-q", "-b", "card-1")
	if err := os.WriteFile(filepath.Join(r.dir, "change.txt"), []byte("the change\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, r.dir, "add", "change.txt")
	git(t, r.dir, "commit", "-q", "-m", "the change")
	sha := git(t, r.dir, "rev-parse", "HEAD")
	git(t, r.dir, "push", "-q", "origin", "card-1")
	// The runner's repository is back on main, and has never fetched card-1.
	git(t, r.dir, "checkout", "-q", "main")
	git(t, r.dir, "branch", "-q", "-D", "card-1")
	git(t, r.dir, "update-ref", "-d", "refs/remotes/origin/card-1")

	me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeContainer{Executor: me}
	r.w.newExecutor = fake.make
	r.w.GOOS = "linux"
	r.w.Offered = []string{executor.Me, executor.Container}
	r.w.Images = []string{"ghcr.io/example/verify:*"}
	r.w.Local.Container = &machine.ContainerSettings{VerifyImage: "ghcr.io/example/verify:1",
		Login: []string{filepath.Join(r.w.Home, ".config", "gh")}, Env: []string{"GH_TOKEN"}}
	return r, fake, sha
}

func TestAVerifyJobRunsInAContainerInItsOwnCloneWithItsOwnToken(t *testing.T) {
	r, fake, sha := verifyRig(t, Config{Model: "sonnet", Instructions: "Be brief.", BeforeHook: "setup"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup")}
	r.w.Local.Models = map[string]string{"schema": "opus"}

	f := r.runJob(fakeJob{id: 401, kind: "verify", card: 42, profile: "schema", prompt: "Check #42", token: testJobToken, sha: sha})
	if f.exit != 0 || f.status != "" {
		t.Fatalf("finish = %+v", f)
	}
	if got := r.srv.header(11).Get("X-Runner-Kinds"); got != "claude,verify,merge,release,probe" {
		t.Fatalf("a machine that can run a container takes verify jobs: %q", got)
	}

	saw := r.agentSaw()
	// Its own clone, at the submitted commit: never the runner's repository.
	if fake.head != sha {
		t.Fatalf("the clone is at %q, want the submitted %s", fake.head, sha)
	}
	if strings.Contains(saw, "dir="+realPath(t, r.dir)+"\n") || !strings.Contains(saw, "slipdock-verify-") {
		t.Fatalf("the agent ran in the runner's repository, not its own clone:\n%s", saw)
	}
	if git(t, r.dir, "rev-parse", "--abbrev-ref", "HEAD") != "main" {
		t.Fatal("the runner's repository moved")
	}
	if matches, _ := filepath.Glob(filepath.Join(os.TempDir(), "slipdock-verify-*", "repo", "change.txt")); len(matches) != 0 {
		t.Fatalf("the clone outlived the job: %v", matches)
	}

	// Its own token and the server, and the server's prompt alone.
	env := func(name, value string) string { return "env=SLIPDOCK_" + name + "=" + value }
	for _, want := range []string{env("TOKEN", testJobToken), env("URL", r.srv.ts.URL),
		env("JOB_KIND", "verify"), "arg=Check #42", "arg=opus"} {
		if !strings.Contains(saw, want+"\n") {
			t.Errorf("the agent didn't get %q:\n%s", want, saw)
		}
	}
	if strings.Contains(saw, "Be brief.") || strings.Contains(saw, "sdm_test_key") {
		t.Fatalf("a verify job gets no instructions and never the machine key:\n%s", saw)
	}

	// The container: the verify image, the agent's login and keys alone.
	if len(fake.settings) == 0 {
		t.Fatal("the job didn't run in the container")
	}
	s := fake.settings[len(fake.settings)-1]
	if s.Image != "ghcr.io/example/verify:1" || s.Repo == r.dir {
		t.Fatalf("settings %+v", s)
	}
	if strings.Join(s.Login, ",") != filepath.Join(r.w.Home, ".claude", ".credentials.json") {
		t.Fatalf("the container mounts %v: want the agent's login alone (no CLI, gh or other login)", s.Login)
	}
	if strings.Join(s.PassEnv, ",") != "CLAUDE_CODE_OAUTH_TOKEN,ANTHROPIC_API_KEY" {
		t.Fatalf("the container gets %v from the daemon: want the agent's keys alone", s.PassEnv)
	}
	// The machine's hooks stay out of a container they weren't written for.
	if ran := r.hooksRan(); ran != "" {
		t.Fatalf("the hooks ran: %q", ran)
	}
	for _, c := range fake.commands {
		if strings.Contains(c, "hook") {
			t.Fatalf("a hook ran in the container: %v", fake.commands)
		}
	}
}

func TestAVerifyJobsTokenNeverReachesTheTranscript(t *testing.T) {
	w := &Worker{Client: &Client{Key: "sdm_k"}, Getenv: func(string) string { return "" }, jobToken: testJobToken}
	if !contains(w.secrets(), testJobToken) {
		t.Fatalf("secrets %v: want the job's token", w.secrets())
	}
}

func TestARunnerThatCantRunAContainerTakesNoVerifyJob(t *testing.T) {
	base := func() *Worker {
		return &Worker{Logf: func(string, ...any) {}, GOOS: "linux",
			Runner:  Runner{Config: Config{Agent: "claude"}},
			Offered: []string{"me", "container"}, Images: []string{"ghcr.io/example/*"},
			Local: machine.Local{Container: &machine.ContainerSettings{VerifyImage: "ghcr.io/example/verify"}}}
	}
	for _, c := range []struct {
		name   string
		change func(*Worker)
		want   string // "" for takes verify
	}{
		{"all there", func(*Worker) {}, ""},
		{"a container runner's own image", func(w *Worker) {
			w.Local.Container = nil
			w.Runner.Config.Executor, w.Runner.Config.Image = executor.Container, "ghcr.io/example/agent"
		}, ""},
		{"no container in the ceiling", func(w *Worker) { w.Offered = []string{"me"} }, "doesn't offer the container"},
		{"no image", func(w *Worker) { w.Local.Container = nil }, "verify_image"},
		{"an image not allowed", func(w *Worker) { w.Images = []string{"ghcr.io/other/*"} }, "allow-list"},
		{"windows", func(w *Worker) { w.GOOS = "windows" }, "container"},
	} {
		w := base()
		c.change(w)
		err, kinds := w.canVerify(), strings.Join(w.kinds(), ",")
		switch {
		case c.want == "" && (err != nil || kinds != "claude,verify,merge,release,probe"):
			t.Errorf("%s: %v, kinds %s", c.name, err, kinds)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want) || strings.Contains(kinds, "verify")):
			t.Errorf("%s: %v, kinds %s; want %q and no verify", c.name, err, kinds, c.want)
		}
	}
}

func TestAVerifyJobARunnerCantContainIsRefused(t *testing.T) {
	r := newRig(t, Config{})
	f := r.runJob(fakeJob{id: 402, kind: "verify", card: 42, prompt: "Check", token: testJobToken})
	if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, "no such job kind: verify") {
		t.Fatalf("finish = %+v", f)
	}
	if strings.Contains(r.agentSaw(), "Check") {
		t.Fatal("the agent ran")
	}
}

func TestAVerifyJobWaitsForThePullRequestsChecks(t *testing.T) {
	r, _, sha := verifyRig(t, Config{})
	pr := "https://github.com/example/repo/pull/7"
	running := `{"headRefOid":"` + sha + `","baseRefName":"main","statusCheckRollup":[{"status":"IN_PROGRESS"},{"state":"SUCCESS"}]}`
	done := `{"headRefOid":"` + sha + `","baseRefName":"main","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"SUCCESS"}]}`
	var mu sync.Mutex
	views := 0
	r.w.Exec = func(ctx context.Context, dir, name string, args ...string) (string, error) {
		if name == "gh" {
			mu.Lock()
			defer mu.Unlock()
			if strings.Join(args, " ") != "pr view "+pr+" --json headRefOid,baseRefName,statusCheckRollup" {
				t.Errorf("gh %v", args)
			}
			views++
			if views < 3 {
				return running, nil
			}
			return done, nil
		}
		return realExec(ctx, dir, name, args...)
	}
	r.w.CIPoll = 20 * time.Millisecond

	f := r.runJob(fakeJob{id: 403, kind: "verify", card: 42, prompt: "Check", token: testJobToken, sha: sha, pr: pr})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if views != 3 {
		t.Fatalf("gh read the pull request %d times: want until its checks finished (3)", views)
	}
	if len(r.srv.beats[403]) < 2 {
		t.Fatalf("the job's lease wasn't kept while it waited: %v", r.srv.beats[403])
	}
	saw := r.agentSaw()
	if !strings.Contains(saw, "env=SLIPDOCK_PR_STATE="+done+"\n") || !strings.Contains(saw, "env=SLIPDOCK_BASE=origin/main\n") {
		t.Fatalf("the agent didn't get the pull request's state:\n%s", saw)
	}
}

func TestAVerifyJobCancelledWhileItWaitsForChecksEnds(t *testing.T) {
	r, _, sha := verifyRig(t, Config{})
	r.w.Exec = func(ctx context.Context, dir, name string, args ...string) (string, error) {
		if name == "gh" {
			return `{"statusCheckRollup":[{"state":"PENDING"}]}`, nil
		}
		return realExec(ctx, dir, name, args...)
	}
	r.w.CIPoll = 10 * time.Millisecond
	r.srv.mu.Lock()
	r.srv.cancel[404] = true
	r.srv.mu.Unlock()
	f := r.runJob(fakeJob{id: 404, kind: "verify", card: 42, prompt: "Check", token: testJobToken, sha: sha,
		pr: "https://github.com/example/repo/pull/7"})
	if f.status != "cancelled" || r.agentSaw() != "" {
		t.Fatalf("finish = %+v; agent saw %q", f, r.agentSaw())
	}
}

func TestTheVerifyHeadersAreReadAsTheyAre(t *testing.T) {
	h := http.Header{}
	h.Set("X-Job-Id", "5")
	h.Set("X-Job-Token", testJobToken)
	h.Set("X-Verify-Commit", "abc1234")
	h.Set("X-Verify-Pr", "https://github.com/example/repo/pull/7")
	job, err := parseJob(h, nil)
	if err != nil || job.Token != testJobToken || job.VerifyCommit != "abc1234" || job.VerifyPR != "https://github.com/example/repo/pull/7" {
		t.Fatalf("job %+v, %v", job, err)
	}
	for header, bad := range map[string]string{
		"X-Job-Token":     "short",
		"X-Verify-Commit": "--upload-pack=x",
		"X-Verify-Pr":     "--repo=other",
	} {
		h := http.Header{}
		h.Set("X-Job-Id", "5")
		h.Set(header, bad)
		job, _ := parseJob(h, nil)
		if job.Token != "" || job.VerifyCommit != "" || job.VerifyPR != "" {
			t.Errorf("%s %q was taken: %+v", header, bad, job)
		}
	}
}

func TestReadPR(t *testing.T) {
	for out, want := range map[string]struct {
		running bool
		base    string
	}{
		`{"baseRefName":"main","statusCheckRollup":[{"status":"COMPLETED"}]}`: {false, "main"},
		`{"baseRefName":"main","statusCheckRollup":[{"status":"QUEUED"}]}`:    {true, "main"},
		`{"baseRefName":"-x","statusCheckRollup":[{"state":"EXPECTED"}]}`:     {true, ""},
		`{"baseRefName":"a b","statusCheckRollup":[]}`:                        {false, ""},
		`not json`: {false, ""},
	} {
		running, base := readPR(out)
		if running != want.running || base != want.base {
			t.Errorf("%s: %v %q, want %v %q", out, running, base, want.running, want.base)
		}
	}
}
