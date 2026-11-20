package runner

import (
	"context"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// Lanes are the machine's job worktrees as its runners use and leave them,
// shared by them all (#3489): which a job is using now, and which a job
// left with uncommitted changes (daemonstate.LeftFile in dir, or in
// memory when dir is ""). Only a worktree listed there is ever pruned, so
// the person's own worktrees, beside the daemon's or not, are never
// touched; and never one a job is using, on this runner or another.
type Lanes struct {
	mu    sync.Mutex
	dir   string
	inUse map[string]int
	mem   []daemonstate.Left
}

// NewLanes keeps the list of left worktrees in dir ("" keeps it in memory).
func NewLanes(dir string) *Lanes {
	return &Lanes{dir: dir, inUse: map[string]int{}}
}

func (l *Lanes) load() ([]daemonstate.Left, error) {
	if l.dir == "" {
		return append([]daemonstate.Left(nil), l.mem...), nil
	}
	return daemonstate.LoadLeft(l.dir)
}

func (l *Lanes) save(left []daemonstate.Left) error {
	if l.dir == "" {
		l.mem = left
		return nil
	}
	return daemonstate.SaveLeft(l.dir, left)
}

// take marks path in use by a job: no sweep touches it until release.
func (l *Lanes) take(path string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.inUse[path]++
}

// drop ends a job's use of path, leaving the list as it is.
func (l *Lanes) drop(path string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.done(path)
}

func (l *Lanes) done(path string) {
	if l.inUse[path]--; l.inUse[path] <= 0 {
		delete(l.inUse, path)
	}
}

// release ends a job's use of path. left, when it isn't nil, is the
// worktree as the job left it, with uncommitted changes: it is listed,
// from left.At. Otherwise the worktree is gone or clean, and isn't.
func (l *Lanes) release(path string, left *daemonstate.Left) error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.done(path)
	list, err := l.load()
	if err != nil {
		return err
	}
	kept := list[:0]
	for _, e := range list {
		if e.Path != path {
			kept = append(kept, e)
		}
	}
	if left != nil {
		kept = append(kept, *left)
	}
	return l.save(kept)
}

// pruned is a worktree a sweep removed: the branch its changes were kept
// on, and whether its card branch was kept too (not merged).
type pruned struct {
	path, branch, keptOn string
	days                 int
	branchKept           bool
}

func (p pruned) String() string {
	s := fmt.Sprintf("worktree %s was left with uncommitted changes %d days ago, untouched since: they were committed to branch %s and the worktree was removed", p.path, p.days, p.keptOn)
	if p.branchKept {
		s += fmt.Sprintf(" (branch %s kept: not merged)", p.branch)
	}
	return s
}

// laneBranch is a card branch as openLane names it.
var laneBranch = regexp.MustCompile(`^card-[0-9]+$`)

// sweeper is what a sweep needs from its worker: git as the account jobs
// run as, that account's view of the files, and the clock.
type sweeper struct {
	run   execFunc
	files executor.Files
	isDir func(string) bool
	now   time.Time
	note  func(string)
}

// sweep prunes repo's worktrees that jobs left with uncommitted changes
// and nobody has touched for age: their changes, untracked files included
// (not ignored ones), are committed to a branch of their own,
// slipdock-kept/card-<id>-<when>, with git's plumbing (no hooks, no
// person's identity), the worktree is removed, and its card branch with
// it when it is merged. A worktree is untouched since the later of when
// it was left and its newest changed file. One a job is using now is left
// alone; one that is now clean, or gone, is no longer listed, and left as
// it is.
func (l *Lanes) sweep(ctx context.Context, s sweeper, repo string, age time.Duration) []pruned {
	if l == nil || age <= 0 {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	list, err := l.load()
	if err != nil {
		s.note(fmt.Sprintf("slipdock-runner: can't read the worktrees left with uncommitted changes: %v", err))
		return nil
	}
	var out []pruned
	kept := list[:0]
	for _, e := range list {
		if e.Repo != repo || l.inUse[e.Path] > 0 {
			kept = append(kept, e)
			continue
		}
		p, keep := s.prune(ctx, e, age)
		if p != nil {
			out = append(out, *p)
		}
		if keep {
			kept = append(kept, e)
		}
	}
	if err := l.save(kept); err != nil {
		s.note(fmt.Sprintf("slipdock-runner: can't write the worktrees left with uncommitted changes: %v", err))
	}
	return out
}

// prune prunes one left worktree if it is old enough, and says whether it
// stays listed.
func (s sweeper) prune(ctx context.Context, e daemonstate.Left, age time.Duration) (*pruned, bool) {
	// Only the daemon's own: <repo>-lanes/card-<id> on card-<id>.
	if !laneBranch.MatchString(e.Branch) || filepath.Clean(e.Path) != filepath.Join(e.Repo+"-lanes", e.Branch) {
		return nil, false
	}
	if !s.isDir(e.Path) {
		return nil, false
	}
	if _, err := s.run(ctx, e.Path, "git", "rev-parse", "--git-dir"); err != nil {
		return nil, false
	}
	st, err := s.run(ctx, e.Path, "git", "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, true
	}
	changed := statusPaths(e.Path, st)
	if len(changed) == 0 {
		s.note(fmt.Sprintf("slipdock-runner: worktree %s has no uncommitted changes now, so it is left as it is", e.Path))
		return nil, false
	}
	if s.now.Sub(e.At) < age {
		return nil, true
	}
	if len(changed) > maxRecent {
		changed = changed[:maxRecent]
	}
	if len(s.files.Recent(changed, s.now.Add(-age))) > 0 {
		return nil, true
	}
	keptOn := fmt.Sprintf("slipdock-kept/%s-%s", e.Branch, s.now.UTC().Format("20060102-150405"))
	if err := s.keep(ctx, e, keptOn); err != nil {
		s.note(fmt.Sprintf("slipdock-runner: worktree %s has had uncommitted changes since %s, but they couldn't be kept on a branch, so it is kept: %v",
			e.Path, e.At.UTC().Format(time.RFC3339), err))
		return nil, true
	}
	if out, err := s.run(ctx, e.Repo, "git", "worktree", "remove", "--force", e.Path); err != nil {
		s.note(fmt.Sprintf("slipdock-runner: worktree %s's changes are kept on branch %s, but the worktree couldn't be removed: %s",
			e.Path, keptOn, oneLine(out)))
		return nil, true
	}
	_, err = s.run(ctx, e.Repo, "git", "branch", "-d", e.Branch)
	return &pruned{path: e.Path, branch: e.Branch, keptOn: keptOn, days: int(s.now.Sub(e.At).Hours() / 24), branchKept: err != nil}, false
}

// maxRecent is the most changed files whose times are read.
const maxRecent = 500

// keep commits everything uncommitted in the worktree, untracked files
// included, to a new branch named on, without moving the worktree's own
// branch: git add -A in its own index (it is about to go), write-tree,
// and commit-tree as the daemon, which runs no hook and needs no
// identity of the person's.
func (s sweeper) keep(ctx context.Context, e daemonstate.Left, on string) error {
	if out, err := s.run(ctx, e.Path, "git", "add", "-A"); err != nil {
		return fmt.Errorf("git add: %s", oneLine(out))
	}
	tree, err := s.run(ctx, e.Path, "git", "write-tree")
	if err != nil {
		return fmt.Errorf("git write-tree: %s", oneLine(tree))
	}
	tree = strings.TrimSpace(tree)
	msg := fmt.Sprintf("Uncommitted changes in %s, kept by slipdock-runner\n\nLeft by a job on %s and untouched since; the worktree was removed.",
		e.Branch, e.At.UTC().Format(time.RFC3339))
	commit, err := s.run(ctx, e.Path, "git", "-c", "user.name=slipdock-runner", "-c", "user.email=runner@example.com",
		"commit-tree", "--no-gpg-sign", tree, "-p", "HEAD", "-m", msg)
	if err != nil {
		return fmt.Errorf("git commit-tree: %s", oneLine(commit))
	}
	commit = strings.TrimSpace(commit)
	if !commitHex.MatchString(commit) {
		return fmt.Errorf("git commit-tree answered %q", oneLine(commit))
	}
	if out, err := s.run(ctx, e.Path, "git", "branch", on, commit); err != nil {
		return fmt.Errorf("git branch %s: %s", on, oneLine(out))
	}
	return nil
}

// statusPaths are the paths, under dir, that git status --porcelain -z
// lists: a rename's or a copy's new path, not its old one.
func statusPaths(dir, st string) []string {
	var out []string
	fields := strings.Split(st, "\x00")
	for i := 0; i < len(fields); i++ {
		f := fields[i]
		if len(f) < 4 {
			continue
		}
		out = append(out, filepath.Join(dir, filepath.FromSlash(f[3:])))
		if f[0] == 'R' || f[0] == 'C' {
			i++
		}
	}
	return out
}

// laneFor opens the job's worktree (openLane) as the machine's Lanes see
// it: in use until the job closes it, and, first, any worktree of the
// same repository a job left with uncommitted changes long enough ago is
// pruned (Lanes.sweep), each one said in the job's log, the daemon's and
// the machine's page.
func (w *Worker) laneFor(ctx context.Context, j *jobRun) (*lane, error) {
	card := j.job.CardID
	path := ""
	if card != 0 {
		if top, err := w.Exec(ctx, j.dir, "git", "rev-parse", "--show-toplevel"); err == nil {
			top = filepath.Clean(strings.TrimSpace(top))
			path = filepath.Join(top+"-lanes", fmt.Sprintf("card-%d", card))
			w.Lanes.take(path)
			w.sweepLanes(ctx, j, top)
		}
	}
	l, err := openLane(ctx, w.Exec, w.Executor.IsDir, j.dir, card, j.note)
	if l == nil || l.path != path {
		if path != "" {
			w.Lanes.drop(path)
		}
		if l != nil {
			w.Lanes.take(l.path)
		}
	}
	if l != nil {
		l.lanes, l.now, l.runner = w.Lanes, w.Now, w.Runner.ID
	}
	return l, err
}

// sweepLanes prunes repo's old dirty worktrees and says so.
func (w *Worker) sweepLanes(ctx context.Context, j *jobRun, repo string) {
	s := sweeper{run: w.Exec, files: w.driftFiles(), isDir: w.Executor.IsDir, now: w.Now(), note: j.note}
	for _, p := range w.Lanes.sweep(ctx, s, repo, w.Local.DirtyWorktreeAge()) {
		line := p.String()
		j.note("slipdock-runner: " + line)
		w.say("warn: %s", line)
		if err := w.Client.ReportWorktree(ctx, w.Runner.ID, line); err != nil {
			w.say("warn: can't put the pruned worktree %s on the machine's page: %v", p.path, err)
		}
	}
}
