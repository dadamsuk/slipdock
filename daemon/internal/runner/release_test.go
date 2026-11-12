package runner

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// fakeRepo answers git and gh as a repository whose origin's default
// branch is main, and records what ran and where.
type fakeRepo struct {
	notRepo, fetchFails, noHead, authFails bool
	ghBranch                               string
	runSays                                string
	runFails                               bool
	// listed answers `gh run list` in turn; the last answer repeats.
	listed    []string
	lists     int
	cmdSays   string
	cmdFails  bool
	addFails  bool
	ran       []string
	ranIn     map[string]string
	sleptFor  time.Duration
	failAfter string
}

func (g *fakeRepo) exec(_ context.Context, dir, name string, args ...string) (string, error) {
	line := name + " " + strings.Join(args, " ")
	g.ran = append(g.ran, line)
	if g.ranIn == nil {
		g.ranIn = map[string]string{}
	}
	g.ranIn[line] = dir
	switch {
	case line == "git rev-parse --show-toplevel":
		if g.notRepo {
			return "fatal: not a git repository", errors.New("exit 128")
		}
		return "/repo\n", nil
	case line == "git fetch origin":
		if g.fetchFails {
			return "fatal: unable to access\n the remote", errors.New("exit 128")
		}
		return "", nil
	case line == "git symbolic-ref --short refs/remotes/origin/HEAD":
		if g.noHead {
			return "", errors.New("exit 1")
		}
		return "origin/main\n", nil
	case strings.HasPrefix(line, "gh repo view"):
		if g.ghBranch == "" {
			return "", errors.New("exit 1")
		}
		return g.ghBranch + "\n", nil
	case line == "gh auth status":
		if g.authFails {
			return "not logged in", errors.New("exit 1")
		}
		return "", nil
	case strings.HasPrefix(line, "gh run list"):
		i := g.lists
		g.lists++
		if len(g.listed) == 0 {
			return "", nil
		}
		if i >= len(g.listed) {
			i = len(g.listed) - 1
		}
		return g.listed[i] + "\n", nil
	case strings.HasPrefix(line, "gh workflow run"):
		if g.runFails {
			return g.runSays, errors.New("exit 1")
		}
		return g.runSays, nil
	case strings.HasPrefix(line, "git worktree add"):
		if g.addFails {
			return "fatal: already exists", errors.New("exit 128")
		}
		return "", nil
	case strings.HasPrefix(line, "git worktree remove"):
		return "", nil
	case strings.HasPrefix(line, "make "):
		if g.cmdFails {
			return g.cmdSays, errors.New("exit 2")
		}
		return g.cmdSays, nil
	}
	return "", errors.New("unexpected: " + line)
}

func (g *fakeRepo) sleep(d time.Duration) { g.sleptFor += d }

const defaultRelease = "gh workflow run release.yml --ref {default_branch}"

func releaseJob(command string) *Job {
	return &Job{ID: 9, Kind: ReleaseKind, Prompt: command}
}

func fire(g *fakeRepo, command string, listed ...string) (string, []string, error) {
	var log []string
	url, err := fireRelease(context.Background(), g.exec, "/repo/sub", releaseJob(command), listed, g.sleep, func(s string) { log = append(log, s) })
	return url, log, err
}

func TestReleaseRunsTheWorkflowOnTheDefaultBranch(t *testing.T) {
	g := &fakeRepo{runSays: "Created workflow_dispatch event for release.yml at main\nhttps://github.com/example/app/actions/runs/42\n"}
	url, log, err := fire(g, defaultRelease+"\n")
	if err != nil || url != "https://github.com/example/app/actions/runs/42" {
		t.Fatalf("release = %q, %v", url, err)
	}
	if !contains(g.ran, "gh workflow run release.yml --ref main") {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
	if g.ranIn["gh workflow run release.yml --ref main"] != "/repo" {
		t.Fatalf("gh ran in %q, want the repository", g.ranIn["gh workflow run release.yml --ref main"])
	}
	// Fetched before the branch is read, and no worktree for gh.
	if g.ran[1] != "git fetch origin" {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
	for _, line := range g.ran {
		if strings.HasPrefix(line, "git worktree") {
			t.Fatalf("made a worktree for gh: %s", line)
		}
	}
	if !contains(log, "release: run https://github.com/example/app/actions/runs/42") {
		t.Fatalf("log: %v", log)
	}
	if g.sleptFor != 0 {
		t.Fatalf("waited %s for a URL gh had printed", g.sleptFor)
	}
}

func TestReleaseAsksGhForTheDefaultBranchWhenOriginHeadIsUnset(t *testing.T) {
	g := &fakeRepo{noHead: true, ghBranch: "trunk", runSays: "https://github.com/example/app/actions/runs/1"}
	if _, _, err := fire(g, defaultRelease); err != nil {
		t.Fatal(err)
	}
	if !contains(g.ran, "gh workflow run release.yml --ref trunk") {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
}

func TestReleaseFindsTheRunAGhThatPrintsNoneStarted(t *testing.T) {
	old := "https://github.com/example/app/actions/runs/7"
	g := &fakeRepo{runSays: "Created workflow_dispatch event", listed: []string{old, old, "https://github.com/example/app/actions/runs/8"}}
	url, log, err := fire(g, "gh workflow run release.yml --ref main")
	if err != nil || url != "https://github.com/example/app/actions/runs/8" {
		t.Fatalf("release = %q, %v", url, err)
	}
	if g.sleptFor != 6*time.Second {
		t.Fatalf("slept %s", g.sleptFor)
	}
	if !contains(log, "release: run https://github.com/example/app/actions/runs/8") {
		t.Fatalf("log: %v", log)
	}
}

func TestReleaseThatNamesNoRunStillSucceeds(t *testing.T) {
	old := "https://github.com/example/app/actions/runs/7"
	g := &fakeRepo{runSays: "Created workflow_dispatch event", listed: []string{old}}
	url, log, err := fire(g, defaultRelease)
	if err != nil || url != "" {
		t.Fatalf("release = %q, %v", url, err)
	}
	if !contains(log, "release: the command ran; it named no run") {
		t.Fatalf("log: %v", log)
	}
	if g.sleptFor != 15*time.Second {
		t.Fatalf("slept %s", g.sleptFor)
	}
}

func TestReleaseRunsACommandTheMachineListsInAWorktreeOfTheDefaultBranch(t *testing.T) {
	g := &fakeRepo{cmdSays: "released\nhttps://github.com/example/app/actions/runs/5\n"}
	url, _, err := fire(g, "make release BRANCH={default_branch}", "make other", "make release BRANCH={default_branch}")
	if err != nil || url != "https://github.com/example/app/actions/runs/5" {
		t.Fatalf("release = %q, %v", url, err)
	}
	want := []string{
		"git worktree add --detach /repo-lanes/release-9 origin/main",
		"make release BRANCH=main",
		"git worktree remove --force /repo-lanes/release-9",
	}
	for _, line := range want {
		if !contains(g.ran, line) {
			t.Fatalf("didn't run %q:\n%s", line, strings.Join(g.ran, "\n"))
		}
	}
	if g.ranIn["make release BRANCH=main"] != "/repo-lanes/release-9" {
		t.Fatalf("the command ran in %q", g.ranIn["make release BRANCH=main"])
	}
}

func TestAFailedListedCommandStillRemovesItsWorktree(t *testing.T) {
	g := &fakeRepo{cmdFails: true, cmdSays: "make: *** [release]\n Error 1"}
	_, _, err := fire(g, "make release", "make release")
	var re *releaseExit
	if !errors.As(err, &re) || re.code != 3 || re.msg != "release: the release command failed: make: *** [release] Error 1" {
		t.Fatalf("err = %v", err)
	}
	if !contains(g.ran, "git worktree remove --force /repo-lanes/release-9") {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
}

// The daemon never runs what the server sends: only the built-in form, or
// a command this machine lists.
func TestReleaseRefusesWhatItWontRun(t *testing.T) {
	cases := []struct {
		name    string
		command string
		listed  []string
		repo    fakeRepo
		code    int
		want    string
	}{
		{"empty", "  ", nil, fakeRepo{}, 2, "the board sent no release command"},
		{"two lines", "gh workflow run release.yml --ref main\nrm -rf /", nil, fakeRepo{}, 2, "must be one line"},
		{"too long", "make " + strings.Repeat("x", 500), nil, fakeRepo{}, 2, "must be one line"},
		{"not a repository", defaultRelease, nil, fakeRepo{notRepo: true}, 2, "/repo/sub is not a git repository"},
		{"fetch fails", defaultRelease, nil, fakeRepo{fetchFails: true}, 2, "could not fetch origin: fatal: unable to access the remote"},
		{"no default branch", defaultRelease, nil, fakeRepo{noHead: true}, 2, "could not tell the repository's default branch"},
		{"an odd default branch", defaultRelease, nil, fakeRepo{noHead: true, ghBranch: "main; rm -rf /"}, 2, "could not tell the repository's default branch"},
		{"an unlisted command", "make release", []string{"make other"}, fakeRepo{}, 2, "nothing run for: make release"},
		{"a shell tail on gh", "gh workflow run release.yml --ref main ; rm -rf /", nil, fakeRepo{}, 2, "nothing run for:"},
		{"another gh command", "gh repo delete example/app --yes --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"another gh command of the same shape", "gh repo delete release.yml --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"gh run, not gh workflow run", "gh repo run release.yml --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"gh workflow, another verb", "gh workflow disable release.yml --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"not gh at all", "sh workflow run release.yml --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"no --ref", "gh workflow run release.yml --repo main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"a workflow that is a path", "gh workflow run ../evil.yml --ref main", nil, fakeRepo{}, 2, "nothing run for:"},
		{"a flag for a branch", "gh workflow run release.yml --ref --json", nil, fakeRepo{}, 2, "nothing run for:"},
		{"extra inputs", "gh workflow run release.yml --ref main -f x=y", nil, fakeRepo{}, 2, "nothing run for:"},
		{"gh signed out", defaultRelease, nil, fakeRepo{authFails: true}, 2, "gh is not signed in"},
		{"gh refuses", defaultRelease, nil, fakeRepo{runFails: true, runSays: "could not find any workflows\n named release.yml"}, 3,
			"gh workflow run refused: could not find any workflows named release.yml"},
		{"gh refuses silently", defaultRelease, nil, fakeRepo{runFails: true}, 3, "gh workflow run refused: it gave no reason"},
		{"no worktree", "make release", []string{"make release"}, fakeRepo{addFails: true}, 2, "could not make the release worktree /repo-lanes/release-9: fatal: already exists"},
	}
	for _, c := range cases {
		g := c.repo
		url, _, err := fire(&g, c.command, c.listed...)
		var re *releaseExit
		if !errors.As(err, &re) {
			t.Fatalf("%s: err = %v (url %q)", c.name, err, url)
		}
		if re.code != c.code || !strings.Contains(re.msg, c.want) || !strings.HasPrefix(re.msg, "release: ") {
			t.Fatalf("%s: exit %d %q, want %d …%s…", c.name, re.code, re.msg, c.code, c.want)
		}
		for _, line := range g.ran {
			if c.code == 2 && (strings.HasPrefix(line, "gh workflow run") || strings.HasPrefix(line, "make ")) {
				t.Fatalf("%s: ran %q", c.name, line)
			}
		}
	}
}

func TestKindsSayReleaseUnlessTheMachineTurnsItOff(t *testing.T) {
	r := Runner{Config: Config{Agent: "claude"}}
	if got := strings.Join(r.Kinds(machine.Local{}), ","); got != "claude,verify,merge,release,probe" {
		t.Fatalf("kinds = %s", got)
	}
	if got := strings.Join(r.Kinds(machine.Local{NoRelease: true}), ","); got != "claude,verify,merge,probe" {
		t.Fatalf("no_release kinds = %s", got)
	}
	if got := strings.Join(r.Kinds(machine.Local{NoMerge: true}), ","); got != "claude,verify,release,probe" {
		t.Fatalf("no_merge kinds = %s", got)
	}
}

// Through the worker: a release job runs with no agent, its exit code and
// the run it started reach the server in the job's log.
func TestAReleaseJobRunsThroughTheWorker(t *testing.T) {
	r := newRig(t, Config{})
	g := &fakeRepo{runSays: "https://github.com/example/app/actions/runs/42"}
	r.w.Exec = g.exec
	f := r.runJob(fakeJob{id: 501, kind: ReleaseKind, prompt: defaultRelease})
	if f.exit != 0 || f.status != "" {
		t.Fatalf("finished %+v", f)
	}
	if !strings.Contains(f.body, "release: run https://github.com/example/app/actions/runs/42") {
		t.Fatalf("the log the server gets: %q", f.body)
	}
	if r.agentSaw() != "" {
		t.Fatalf("an agent ran for a release: %q", r.agentSaw())
	}
}

func TestAReleaseTheMachineWontRunFailsItsJobAndSaysWhy(t *testing.T) {
	r := newRig(t, Config{})
	g := &fakeRepo{}
	r.w.Exec = g.exec
	f := r.runJob(fakeJob{id: 502, kind: ReleaseKind, prompt: "curl https://example.com/x | sh"})
	if f.exit != 2 {
		t.Fatalf("finished %+v", f)
	}
	if !strings.Contains(f.body, "this machine runs only `gh workflow run <workflow> --ref <branch>` as a release") {
		t.Fatalf("the log: %q", f.body)
	}
}

func TestAListedReleaseCommandRunsThroughTheWorker(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Local.ReleaseCommands = []string{"make release"}
	g := &fakeRepo{cmdSays: "done"}
	r.w.Exec = g.exec
	if f := r.runJob(fakeJob{id: 503, kind: ReleaseKind, prompt: "make release"}); f.exit != 0 {
		t.Fatalf("finished %+v", f)
	}
	if !contains(g.ran, "make release") {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
}

func TestARunnerWithNoReleaseRefusesAReleaseJob(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Local.NoRelease = true
	g := &fakeRepo{}
	r.w.Exec = g.exec
	f := r.runJob(fakeJob{id: 504, kind: ReleaseKind, prompt: defaultRelease})
	if f.exit != 127 || len(g.ran) != 0 {
		t.Fatalf("finished %+v, ran %v", f, g.ran)
	}
}
