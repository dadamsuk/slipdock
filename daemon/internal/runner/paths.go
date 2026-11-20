package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// A card's paths (#3521) are, under confined and container, the only
// paths in its worktree its agent may write. Landlock and a bind mount
// grant whole directories and files that exist, so each glob is turned
// into one real path beneath the worktree:
//
//   - a glob with a wildcard (`*`, `?`, `[`) grants its deepest fixed
//     directory, made if it isn't there: `lib/foo/**/*.ex` grants
//     lib/foo, all of it;
//   - a path with no wildcard grants itself when it is there (a file, or
//     a directory and all of it), else the directory it would be in, made:
//     a new file in lib/foo grants lib/foo;
//   - a glob whose fixed directory is the top of the worktree (`*.md`,
//     `**/x.ex`, a new file at the top) grants the whole worktree, as a
//     card with no paths has it;
//   - braces are expanded (`{a,b}`), at most maxExpansions globs;
//   - one that is absolute, climbs out with `..`, names the worktree's
//     .git, or is (or is through) a link out of the worktree grants
//     nothing, and the job's log says so.
//
// A commit still needs the repository's objects, refs and logs and the
// worktree's own git directory (its index and HEAD), so those are
// writable; the rest of the repository (its config, its hooks, the main
// checkout) is not. The worktree's own git directory says where the
// repository is (commondir, gitdir) and could hold config of its own
// (config.worktree): those are pinned before the agent starts and put back
// when it ends, before a hook or the daemon's own git reads them.

const maxExpansions = 64

// cardPaths are the real paths a job in the worktree root may write for
// the globs, with a note for each glob that grants nothing. gitDir is the
// worktree's own git directory and commonDir the repository's.
func cardPaths(root, gitDir, commonDir string, globs []string) (paths, notes []string, err error) {
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return nil, nil, err
	}
	if gitDir, err = filepath.EvalSymlinks(gitDir); err != nil {
		return nil, nil, err
	}
	if commonDir, err = filepath.EvalSymlinks(commonDir); err != nil {
		return nil, nil, err
	}
	if !within(filepath.Join(commonDir, "worktrees"), gitDir) || gitDir == filepath.Join(commonDir, "worktrees") {
		return nil, nil, fmt.Errorf("%s is not a worktree of its own (its git directory is %s), so the card's paths can't be kept to", root, gitDir)
	}
	seen := map[string]bool{}
	add := func(p string) {
		if !seen[p] {
			seen[p] = true
			paths = append(paths, p)
		}
	}
	for _, g := range globs {
		for _, e := range expandBraces(strings.TrimSpace(g)) {
			p, why := globPath(root, e)
			if why != "" {
				notes = append(notes, fmt.Sprintf("the card's path %q grants nothing: %s", g, why))
				continue
			}
			add(p)
		}
	}
	for _, d := range []string{"objects", "refs", "logs"} {
		p, err := madeBeneath(commonDir, filepath.Join(commonDir, d))
		if err != nil {
			return nil, nil, err
		}
		add(p)
	}
	add(gitDir)
	return paths, notes, nil
}

// globPath is the real path beneath root that glob grants, or why none.
func globPath(root, glob string) (string, string) {
	glob = strings.TrimPrefix(glob, "./")
	if glob == "" {
		return "", "it is empty"
	}
	if strings.HasPrefix(glob, "/") || strings.HasPrefix(glob, "~") || strings.HasPrefix(glob, `\`) ||
		(len(glob) > 1 && glob[1] == ':') {
		return "", "it isn't relative to the repository"
	}
	var segs []string
	for _, s := range strings.Split(glob, "/") {
		switch s {
		case "", ".":
			continue
		case "..":
			return "", "it has a .."
		}
		segs = append(segs, s)
	}
	if len(segs) == 0 {
		return root, ""
	}
	if segs[0] == ".git" {
		return "", "the worktree's .git is never writable"
	}
	fixed := len(segs)
	for i, s := range segs {
		if strings.ContainsAny(s, "*?[") {
			fixed = i
			break
		}
	}
	target := filepath.Join(append([]string{root}, segs[:fixed]...)...)
	if fixed == len(segs) {
		if _, err := os.Lstat(target); err != nil {
			target = filepath.Dir(target)
		}
	}
	p, err := madeBeneath(root, target)
	if err != nil {
		return "", err.Error()
	}
	if p == filepath.Join(root, ".git") {
		return "", "the worktree's .git is never writable"
	}
	return p, ""
}

// madeBeneath is target's real path, made a directory if it isn't there,
// so long as it is beneath root (a real path) and gets there through no
// link out of it.
func madeBeneath(root, target string) (string, error) {
	have, rest := target, ""
	for {
		if _, err := os.Lstat(have); err == nil {
			break
		}
		parent := filepath.Dir(have)
		if parent == have {
			return "", fmt.Errorf("%s isn't there", target)
		}
		rest = filepath.Join(filepath.Base(have), rest)
		have = parent
	}
	real, err := filepath.EvalSymlinks(have)
	if err != nil {
		return "", fmt.Errorf("%s: %v", have, err)
	}
	if !within(root, real) {
		return "", fmt.Errorf("%s is a link out of %s", have, root)
	}
	if rest == "" {
		return real, nil
	}
	if fi, err := os.Stat(real); err != nil || !fi.IsDir() {
		return "", fmt.Errorf("%s is not a directory", real)
	}
	made := filepath.Join(real, rest)
	if err := os.MkdirAll(made, 0o755); err != nil {
		return "", err
	}
	if again, err := filepath.EvalSymlinks(made); err != nil || again != made {
		return "", fmt.Errorf("%s moved as it was made", made)
	}
	return made, nil
}

// within says whether path is dir or beneath it.
func within(dir, path string) bool {
	return path == dir || strings.HasPrefix(path, dir+string(filepath.Separator))
}

// expandBraces expands {a,b} (innermost first), to at most maxExpansions
// globs, as the server does (Slipdock.Lanes).
func expandBraces(glob string) []string {
	out := []string{glob}
	for {
		var next []string
		grew := false
		for _, g := range out {
			end := strings.Index(g, "}")
			start := -1
			if end > 0 {
				start = strings.LastIndex(g[:end], "{")
			}
			if start < 0 {
				next = append(next, g)
				continue
			}
			grew = true
			for _, opt := range strings.Split(g[start+1:end], ",") {
				next = append(next, g[:start]+opt+g[end+1:])
			}
		}
		if len(next) > maxExpansions {
			next = next[:maxExpansions]
		}
		out = next
		if !grew {
			return out
		}
	}
}

// pins are the files of a worktree's git directory that say where its
// repository is, as they were before the agent started: put back when it
// ends, and what wasn't there removed.
type pins struct {
	files  map[string][]byte
	absent []string
}

// pin records the worktree's .git and its git directory's commondir,
// gitdir and config.worktree.
func pin(root, gitDir string) *pins {
	pn := &pins{files: map[string][]byte{}}
	for _, f := range []string{filepath.Join(root, ".git"), filepath.Join(gitDir, "commondir"),
		filepath.Join(gitDir, "gitdir"), filepath.Join(gitDir, "config.worktree")} {
		fi, err := os.Lstat(f)
		switch {
		case errors.Is(err, os.ErrNotExist):
			pn.absent = append(pn.absent, f)
		case err == nil && fi.Mode().IsRegular():
			if data, err := os.ReadFile(f); err == nil {
				pn.files[f] = data
			}
		}
	}
	return pn
}

// restore puts the pinned files back as they were, never through a link
// the job left in their place, and says what it put back.
func (pn *pins) restore(note func(string)) {
	if pn == nil {
		return
	}
	for f, want := range pn.files {
		if fi, err := os.Lstat(f); err == nil && fi.Mode().IsRegular() {
			if data, err := os.ReadFile(f); err == nil && bytes.Equal(data, want) {
				continue
			}
		}
		if err := os.RemoveAll(f); err != nil {
			note(fmt.Sprintf("slipdock-runner: can't put back %s: %v", f, err))
			continue
		}
		fh, err := os.OpenFile(f, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err == nil {
			_, err = fh.Write(want)
			if cerr := fh.Close(); err == nil {
				err = cerr
			}
		}
		if err != nil {
			note(fmt.Sprintf("slipdock-runner: can't put back %s: %v", f, err))
			continue
		}
		note(fmt.Sprintf("slipdock-runner: the job changed %s, which is put back", f))
	}
	for _, f := range pn.absent {
		if _, err := os.Lstat(f); err == nil {
			if err := os.RemoveAll(f); err != nil {
				note(fmt.Sprintf("slipdock-runner: can't remove %s: %v", f, err))
				continue
			}
			note(fmt.Sprintf("slipdock-runner: the job made %s, which is removed", f))
		}
	}
}

// confinesPaths says whether the executor keeps a job to its card's paths.
func confinesPaths(name string) bool {
	return name == executor.Confined || name == executor.Container
}

// keepToPaths is what a confined or container job in a worktree may write
// when its card has paths, and the worktree's own git directory; nil for a
// job that may write the whole worktree (no paths, no worktree, another
// executor). An error means the job must not run.
func (w *Worker) keepToPaths(ctx context.Context, j *jobRun) ([]string, string, error) {
	job := j.job
	if !confinesPaths(w.Executor.Name()) || j.lane == nil {
		return nil, "", nil
	}
	if job.PathsBad {
		return nil, "", errors.New("the server sent card paths this runner can't read, so the job was not run")
	}
	if len(job.Paths) == 0 {
		return nil, "", nil
	}
	out, err := w.Exec(ctx, j.lane.path, "git", "rev-parse", "--git-dir", "--git-common-dir")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if err != nil || len(lines) != 2 {
		return nil, "", fmt.Errorf("can't find the git directories of %s, so the card's paths can't be kept to and the job was not run", j.lane.path)
	}
	for i, l := range lines {
		if !filepath.IsAbs(l) {
			lines[i] = filepath.Join(j.lane.path, l)
		}
	}
	paths, notes, err := cardPaths(j.lane.path, lines[0], lines[1], job.Paths)
	if err != nil {
		return nil, "", fmt.Errorf("%v; the job was not run", err)
	}
	for _, n := range notes {
		j.note("slipdock-runner: " + n)
	}
	j.note("slipdock-runner: the job may write only its card's paths in the worktree: " + strings.Join(paths, ", "))
	return paths, lines[0], nil
}
