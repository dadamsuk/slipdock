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
		// Every new worktree starts at the origin's default branch as
		// fetched now (#3002). A card branch already there with nothing
		// of its own is moved up to it; one with commits of its own (a
		// rejected card's earlier attempt, here or only on the origin) is
		// rebased onto it in the new worktree.
		from := laneBase(ctx, run, top, note)
		args, rebase := []string{"worktree", "add", path, branch}, ""
		switch {
		case hasRef(ctx, run, top, "refs/heads/"+branch):
			if from != "HEAD" && isAncestor(ctx, run, top, branch, from) {
				args = []string{"worktree", "add", "--no-track", "-B", branch, path, from}
				note(fmt.Sprintf("slipdock-runner: branch %s had nothing of its own, so it starts again from %s", branch, from))
			} else if from != "HEAD" {
				rebase = branch
			}
		case from != "HEAD" && hasRef(ctx, run, top, "refs/remotes/origin/"+branch):
			args = []string{"worktree", "add", "--no-track", "-b", branch, path, "origin/" + branch}
			rebase = "origin/" + branch
		default:
			args = []string{"worktree", "add", "--no-track", "-b", branch, path, from}
		}
		if out, err := run(ctx, top, "git", args...); err != nil {
			note(out)
			return nil, fmt.Errorf("could not make worktree %s, so the job was not run", path)
		}
		switch {
		case rebase != "" && rebase != branch:
			note(fmt.Sprintf("slipdock-runner: worktree %s on branch %s, from %s", path, branch, rebase))
			rebaseLane(ctx, run, path, branch, from, note)
		case len(args) == 4:
			note(fmt.Sprintf("slipdock-runner: worktree %s on branch %s", path, branch))
			if rebase != "" {
				rebaseLane(ctx, run, path, branch, from, note)
			}
		default:
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

// rebaseLane puts the card branch's own commits on top of base, so the
// job starts from what the origin has now. A rebase that stops (a
// conflict, a dirty tree) is aborted, the branch left as it was, and the
// log says how far behind base it is, for the agent to rebase.
func rebaseLane(ctx context.Context, run execFunc, path, branch, base string, note func(string)) {
	if isAncestor(ctx, run, path, base, "HEAD") {
		return
	}
	if _, err := run(ctx, path, "git", "rebase", "--quiet", base); err == nil {
		note(fmt.Sprintf("slipdock-runner: branch %s rebased onto %s", branch, base))
		return
	}
	run(ctx, path, "git", "rebase", "--abort")
	behind, _ := run(ctx, path, "git", "rev-list", "--count", "HEAD.."+base)
	note(fmt.Sprintf("slipdock-runner: branch %s didn't rebase cleanly onto %s, so it is left as it was, %s commits behind: rebase it before building on it", branch, base, strings.TrimSpace(behind)))
}

func hasRef(ctx context.Context, run execFunc, dir, ref string) bool {
	_, err := run(ctx, dir, "git", "show-ref", "--verify", "--quiet", ref)
	return err == nil
}

// isAncestor says whether a is already in b's history.
func isAncestor(ctx context.Context, run execFunc, dir, a, b string) bool {
	_, err := run(ctx, dir, "git", "merge-base", "--is-ancestor", a, b)
	return err == nil
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
