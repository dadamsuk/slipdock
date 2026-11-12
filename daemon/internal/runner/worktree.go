package runner

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
)

// lane is a job's own git worktree, as the shell runner's WORKTREE=1 makes
// it: on a branch named for the card (card-<id>), beside the repository in
// <repo>-lanes, so jobs side by side never share a working tree.
type lane struct {
	path, repo, branch string
}

// openLane makes (or reuses) the card's worktree for a job in dir. With no
// card or no repository there is none, and the log says the job runs in
// place; an error means the worktree couldn't be made, and the job must
// not run, since running it in the shared tree is what the setting is for.
//
// isDir looks as the account jobs run as, whose worktrees they are.
func openLane(ctx context.Context, run execFunc, isDir func(string) bool, dir string, card int64, note func(string)) (*lane, error) {
	if card == 0 {
		note(fmt.Sprintf("slipdock-runner: the job has no card, so no worktree; it runs in %s", dir))
		return nil, nil
	}
	top, err := run(ctx, dir, "git", "rev-parse", "--show-toplevel")
	if err != nil {
		note(fmt.Sprintf("slipdock-runner: %s is not a git repository, so no worktree; the job runs in %s", dir, dir))
		return nil, nil
	}
	top = filepath.Clean(strings.TrimSpace(top))
	branch := fmt.Sprintf("card-%d", card)
	path := filepath.Join(top+"-lanes", branch)
	if isDir(path) {
		if _, err := run(ctx, path, "git", "rev-parse", "--git-dir"); err != nil {
			return nil, fmt.Errorf("%s is there but is not a worktree, so the job was not run", path)
		}
		on, _ := run(ctx, path, "git", "rev-parse", "--abbrev-ref", "HEAD")
		note(fmt.Sprintf("slipdock-runner: worktree %s (kept from before) on %s", path, strings.TrimSpace(on)))
	} else {
		// A card branch already there (a rejected card's earlier attempt)
		// is checked out as it is; a new one starts from the origin's
		// default branch.
		args, from := []string{"worktree", "add", path, branch}, ""
		if _, err := run(ctx, top, "git", "show-ref", "--verify", "--quiet", "refs/heads/"+branch); err != nil {
			from = laneBase(ctx, run, top, note)
			args = []string{"worktree", "add", "--no-track", "-b", branch, path, from}
		}
		if out, err := run(ctx, top, "git", args...); err != nil {
			note(out)
			return nil, fmt.Errorf("could not make worktree %s, so the job was not run", path)
		}
		if from == "" {
			note(fmt.Sprintf("slipdock-runner: worktree %s on branch %s", path, branch))
		} else {
			note(fmt.Sprintf("slipdock-runner: worktree %s on branch %s, from %s", path, branch, from))
		}
	}
	return &lane{path: path, repo: top, branch: branch}, nil
}

// laneBase is what a new card branch starts from: the origin's default
// branch, fetched first, never the shared checkout's HEAD, which can sit
// on another card's branch (#2758). With no origin, or no default branch
// on it, HEAD it is, and the log says so. A fetch that fails leaves the
// origin's branch as it was last fetched.
func laneBase(ctx context.Context, run execFunc, top string, note func(string)) string {
	if _, err := run(ctx, top, "git", "remote", "get-url", "origin"); err != nil {
		note("slipdock-runner: the repository has no origin remote, so the worktree starts from HEAD")
		return "HEAD"
	}
	if out, err := run(ctx, top, "git", "fetch", "--quiet", "origin"); err != nil {
		note(fmt.Sprintf("slipdock-runner: git fetch origin failed, so the worktree starts from origin as last fetched: %s", strings.TrimSpace(out)))
	}
	if ref, err := run(ctx, top, "git", "rev-parse", "--abbrev-ref", "origin/HEAD"); err == nil {
		if ref = strings.TrimSpace(ref); strings.HasPrefix(ref, "origin/") && ref != "origin/HEAD" {
			return ref
		}
	}
	for _, ref := range []string{"origin/main", "origin/master"} {
		if _, err := run(ctx, top, "git", "rev-parse", "--verify", "--quiet", ref+"^{commit}"); err == nil {
			return ref
		}
	}
	note("slipdock-runner: origin has no default branch here, so the worktree starts from HEAD")
	return "HEAD"
}

// close removes a clean worktree, and its branch if it is merged (git
// branch -d); anything uncommitted keeps it.
func (l *lane) close(ctx context.Context, run execFunc, note func(string)) {
	if l == nil {
		return
	}
	if st, err := run(ctx, l.path, "git", "status", "--porcelain"); err != nil || strings.TrimSpace(st) != "" {
		note(fmt.Sprintf("slipdock-runner: worktree %s has uncommitted changes, so it is kept", l.path))
		return
	}
	if _, err := run(ctx, l.repo, "git", "worktree", "remove", l.path); err != nil {
		note(fmt.Sprintf("slipdock-runner: could not remove worktree %s, so it is kept", l.path))
		return
	}
	if _, err := run(ctx, l.repo, "git", "branch", "-d", l.branch); err == nil {
		note(fmt.Sprintf("slipdock-runner: worktree %s removed", l.path))
	} else {
		note(fmt.Sprintf("slipdock-runner: worktree %s removed; branch %s kept (not merged)", l.path, l.branch))
	}
}
