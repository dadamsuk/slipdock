package runner

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

const day = 24 * time.Hour

// gitIn runs git in dir as a test's own user, and answers what it printed.
func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main"}, args...)...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// clock is a test's w.Now.
type clock struct {
	mu sync.Mutex
	at time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

// A worktree a job left with uncommitted changes is kept for the next
// job while it is young, and, once untouched for dirty_worktree_days
// (14 by default), its changes go on a branch of their own, it is
// removed, and the job's log, the daemon's and the machine's page say so
// (#3489).
func TestAWorktreeLeftDirtyIsKeptOnABranchThenPruned(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	r := newRig(t, Config{Worktree: "on"})
	gitIn(t, r.dir, "init", "-q")
	gitIn(t, r.dir, "commit", "-q", "--allow-empty", "-m", "start")
	top := filepath.Clean(gitIn(t, r.dir, "rev-parse", "--show-toplevel"))
	c := &clock{at: time.Now()}
	r.w.Now = c.now

	t.Setenv("HELPER_LEAVE", "left.txt")
	f := r.runJob(fakeJob{id: 160, kind: "claude", card: 70, prompt: "x"})
	lane := filepath.Join(top+"-lanes", "card-70")
	if !strings.Contains(f.body, "worktree "+lane+" has uncommitted changes, so it is kept") {
		t.Fatalf("log: %s", f.body)
	}
	left, err := daemonstate.LoadLeft(filepath.Dir(r.w.JobsDir))
	if err != nil || len(left) != 1 || left[0].Path != lane || left[0].Branch != "card-70" || left[0].Runner != 11 || !left[0].At.Equal(c.at) {
		t.Fatalf("left = %+v %v", left, err)
	}

	// Young: 13 days on, the next job leaves it as it is.
	t.Setenv("HELPER_LEAVE", "")
	c.add(13 * day)
	f = r.runJob(fakeJob{id: 161, kind: "claude", card: 71, prompt: "x"})
	if _, err := os.Stat(filepath.Join(lane, "left.txt")); err != nil {
		t.Fatalf("a young dirty worktree is kept: %v\n%s", err, f.body)
	}
	if strings.Contains(f.body, "card-70") || len(r.srv.reports) != 0 {
		t.Fatalf("nothing said of it: %s %v", f.body, r.srv.reports)
	}

	// Old: 15 days on, it is kept on a branch and pruned.
	c.add(2 * day)
	f = r.runJob(fakeJob{id: 162, kind: "claude", card: 72, prompt: "x"})
	if _, err := os.Stat(lane); !os.IsNotExist(err) {
		t.Fatalf("an old dirty worktree is removed: %v\n%s", err, f.body)
	}
	kept := gitIn(t, r.dir, "for-each-ref", "--format=%(refname:short)", "refs/heads/slipdock-kept/")
	if !strings.HasPrefix(kept, "slipdock-kept/card-70-") || strings.Contains(kept, "\n") {
		t.Fatalf("kept branches: %q", kept)
	}
	if got := gitIn(t, r.dir, "show", kept+":left.txt"); got != "work in progress" {
		t.Fatalf("the kept branch has the change: %q", got)
	}
	if got := gitIn(t, r.dir, "log", "-1", "--format=%an <%ae>", kept); got != "slipdock-runner <runner@example.com>" {
		t.Fatalf("kept as %q", got)
	}
	// card-70 had nothing of its own, so it went with the worktree.
	if out, err := exec.Command("git", "-C", r.dir, "rev-parse", "--verify", "--quiet", "refs/heads/card-70").CombinedOutput(); err == nil {
		t.Fatalf("branch card-70 is merged, so removed: %s", out)
	}
	want := "worktree " + lane + " was left with uncommitted changes 15 days ago, untouched since: they were committed to branch " + kept + " and the worktree was removed"
	if !strings.Contains(f.body, "slipdock-runner: "+want) {
		t.Fatalf("the job's log says so: %s", f.body)
	}
	if !strings.Contains(r.logged.String(), want) {
		t.Fatalf("the daemon's log says so: %s", r.logged.String())
	}
	if len(r.srv.reports) != 1 || r.srv.reports[0]["outcome"] != "worktree_pruned" || r.srv.reports[0]["reason"] != want || r.srv.reports[0]["runner"] != int64(11) {
		t.Fatalf("the machine's page is told: %v", r.srv.reports)
	}
	if left, _ := daemonstate.LoadLeft(filepath.Dir(r.w.JobsDir)); len(left) != 0 {
		t.Fatalf("no longer listed: %+v", left)
	}

	// The job's own card's worktree, however old, is the job's to use.
	t.Setenv("HELPER_LEAVE", "left.txt")
	r.runJob(fakeJob{id: 163, kind: "claude", card: 73, prompt: "x"})
	t.Setenv("HELPER_LEAVE", "")
	c.add(30 * day)
	f = r.runJob(fakeJob{id: 164, kind: "claude", card: 73, prompt: "x"})
	lane = filepath.Join(top+"-lanes", "card-73")
	if !strings.Contains(f.body, "worktree "+lane+" (kept from before)") || strings.Contains(f.body, "slipdock-kept/card-73") || len(r.srv.reports) != 1 {
		t.Fatalf("log: %s", f.body)
	}
	if left, _ := daemonstate.LoadLeft(filepath.Dir(r.w.JobsDir)); len(left) != 1 || !left[0].At.Equal(c.at) {
		t.Fatalf("listed again from when this job left it: %+v", left)
	}
}

// laneRepo is a repository with a commit, and a worktree of it for card
// id as openLane makes one, listed as left at at.
type laneRepo struct {
	top   string
	lanes *Lanes
}

func newLaneRepo(t *testing.T) *laneRepo {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("*.log\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "add", "a.txt", ".gitignore")
	gitIn(t, dir, "commit", "-q", "-m", "start")
	return &laneRepo{top: filepath.Clean(gitIn(t, dir, "rev-parse", "--show-toplevel")), lanes: NewLanes(t.TempDir())}
}

// lane makes card-<id>'s worktree and lists it as left at at.
func (r *laneRepo) lane(t *testing.T, id string, at time.Time) string {
	t.Helper()
	path := filepath.Join(r.top+"-lanes", "card-"+id)
	gitIn(t, r.top, "worktree", "add", "-q", "-b", "card-"+id, path)
	r.lanes.take(path)
	if err := r.lanes.release(path, &daemonstate.Left{Path: path, Repo: r.top, Branch: "card-" + id, Runner: 1, At: at}); err != nil {
		t.Fatal(err)
	}
	return path
}

func (r *laneRepo) sweep(t *testing.T, now time.Time, age time.Duration) ([]pruned, string) {
	t.Helper()
	var said strings.Builder
	s := sweeper{run: realExec, files: executor.LocalFiles, isDir: func(p string) bool {
		fi, err := os.Stat(p)
		return err == nil && fi.IsDir()
	}, now: now, note: func(l string) { said.WriteString(l + "\n") }}
	return r.lanes.sweep(context.Background(), s, r.top, age), said.String()
}

func listed(t *testing.T, l *Lanes) []string {
	t.Helper()
	left, err := l.load()
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range left {
		out = append(out, filepath.Base(e.Path))
	}
	return out
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// What a sweep keeps of an old worktree: its tracked changes, staged or
// not, and its untracked files, never its ignored ones, on a branch whose
// parent is the card branch's head, which is left where it was and kept
// when it has commits of its own.
func TestASweepKeepsEveryUncommittedChangeOnABranch(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	r := newLaneRepo(t)
	start := time.Now().Add(-30 * day)
	lane := r.lane(t, "5", start)
	write(t, filepath.Join(lane, "own.txt"), "own\n")
	gitIn(t, lane, "add", "own.txt")
	gitIn(t, lane, "commit", "-q", "-m", "card 5's own")
	head := gitIn(t, lane, "rev-parse", "HEAD")
	write(t, filepath.Join(lane, "a.txt"), "changed\n")
	write(t, filepath.Join(lane, "staged.txt"), "staged\n")
	gitIn(t, lane, "add", "staged.txt")
	if err := os.MkdirAll(filepath.Join(lane, "new"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(lane, "new", "b.txt"), "untracked\n")
	write(t, filepath.Join(lane, "debug.log"), "ignored\n")
	// Every file's time is long past.
	old := time.Now().Add(-20 * day)
	for _, f := range []string{"a.txt", "staged.txt", "new/b.txt", "debug.log", "own.txt"} {
		if err := os.Chtimes(filepath.Join(lane, f), old, old); err != nil {
			t.Fatal(err)
		}
	}

	got, _ := r.sweep(t, time.Now(), 14*day)
	if len(got) != 1 || got[0].path != lane || !got[0].branchKept || got[0].days != 30 {
		t.Fatalf("pruned = %+v", got)
	}
	if !strings.HasSuffix(got[0].String(), "(branch card-5 kept: not merged)") {
		t.Fatalf("says the card branch was kept: %s", got[0])
	}
	if _, err := os.Stat(lane); !os.IsNotExist(err) {
		t.Fatalf("removed: %v", err)
	}
	kept := got[0].keptOn
	files := gitIn(t, r.top, "ls-tree", "-r", "--name-only", kept)
	if files != strings.Join([]string{".gitignore", "a.txt", "new/b.txt", "own.txt", "staged.txt"}, "\n") {
		t.Fatalf("kept files:\n%s", files)
	}
	if a := gitIn(t, r.top, "show", kept+":a.txt"); a != "changed" {
		t.Fatalf("a.txt = %q", a)
	}
	if p := gitIn(t, r.top, "rev-parse", kept+"^"); p != head {
		t.Fatalf("parent %s, want card-5's head %s", p, head)
	}
	if b := gitIn(t, r.top, "rev-parse", "card-5"); b != head {
		t.Fatalf("card-5 moved to %s", b)
	}
	if l := listed(t, r.lanes); len(l) != 0 {
		t.Fatalf("still listed: %v", l)
	}
}

// A sweep leaves alone a worktree that is young, touched since it was
// left, in use by a job, now clean, or another repository's, and never one
// it didn't list (#3489).
func TestASweepPrunesOnlyOldListedDirtyWorktreesNobodyUses(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	r := newLaneRepo(t)
	now := time.Now()
	old := now.Add(-20 * day)
	dirty := func(lane string, at time.Time) {
		t.Helper()
		write(t, filepath.Join(lane, "a.txt"), "changed\n")
		if err := os.Chtimes(filepath.Join(lane, "a.txt"), at, at); err != nil {
			t.Fatal(err)
		}
	}
	young := r.lane(t, "1", now.Add(-13*day))
	dirty(young, old)
	touched := r.lane(t, "2", old)
	dirty(touched, now.Add(-day))
	busy := r.lane(t, "3", old)
	dirty(busy, old)
	r.lanes.take(busy)
	clean := r.lane(t, "4", old)
	gone := r.lane(t, "6", old)
	gitIn(t, r.top, "worktree", "remove", "--force", gone)
	// The person's own worktree, beside the daemon's: never listed.
	own := filepath.Join(r.top+"-lanes", "card-7")
	gitIn(t, r.top, "worktree", "add", "-q", "-b", "card-7", own)
	dirty(own, old)
	// Another repository's, listed: not this sweep's.
	other := daemonstate.Left{Path: filepath.Join(t.TempDir()+"-lanes", "card-8"), Repo: t.TempDir(), Branch: "card-8", At: old}
	r.lanes.take(other.Path)
	if err := r.lanes.release(other.Path, &other); err != nil {
		t.Fatal(err)
	}

	// Listed, but not where or what the daemon makes: never touched, and
	// no longer listed.
	var strays []string
	for _, at := range [][2]string{{r.top + "-elsewhere", "card-9"}, {r.top + "-lanes", "feature"}} {
		path := filepath.Join(at[0], at[1])
		gitIn(t, r.top, "worktree", "add", "-q", "-b", at[1], path)
		dirty(path, old)
		r.lanes.take(path)
		if err := r.lanes.release(path, &daemonstate.Left{Path: path, Repo: r.top, Branch: at[1], At: old}); err != nil {
			t.Fatal(err)
		}
		strays = append(strays, path)
	}

	got, said := r.sweep(t, now, 14*day)
	for _, path := range strays {
		if _, err := os.Stat(filepath.Join(path, "a.txt")); err != nil {
			t.Errorf("%s: %v", path, err)
		}
	}
	if len(got) != 0 {
		t.Fatalf("pruned %+v", got)
	}
	for _, lane := range []string{young, touched, busy, clean, own} {
		if _, err := os.Stat(lane); err != nil {
			t.Errorf("%s: %v", lane, err)
		}
	}
	if !strings.Contains(said, "worktree "+clean+" has no uncommitted changes now, so it is left as it is") {
		t.Fatalf("said: %s", said)
	}
	if l := strings.Join(listed(t, r.lanes), " "); l != "card-1 card-2 card-3 card-8" {
		t.Fatalf("listed: %s", l)
	}
	if out := gitIn(t, r.top, "branch", "--list", "slipdock-kept/*"); out != "" {
		t.Fatalf("nothing kept: %s", out)
	}

	// Never, with dirty_worktree_days 0.
	if got, _ := r.sweep(t, now.Add(365*day), 0); len(got) != 0 {
		t.Fatalf("age 0 pruned %+v", got)
	}
	// Once the job ends with it clean, it is no longer listed; and a
	// year on, the others are pruned.
	r.lanes.drop(busy)
	got, _ = r.sweep(t, now.Add(365*day), 14*day)
	if len(got) != 3 {
		t.Fatalf("a year on, pruned %+v", got)
	}
	if l := strings.Join(listed(t, r.lanes), " "); l != "card-8" {
		t.Fatalf("listed: %s", l)
	}
	if _, err := os.Stat(own); err != nil {
		t.Fatalf("the person's own worktree: %v", err)
	}
}
