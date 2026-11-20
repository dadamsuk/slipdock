package executor

import (
	"os"
	"path/filepath"
	"sort"
)

// Unreadable are the logins under the home that no confined job needs, by
// path under it: cloud, container and cluster credentials, .netrc and the
// GnuPG keys. What a job does need stays readable: ~/.ssh (git over ssh),
// gh's login (pull requests) and the slipdock CLI's (the board).
var Unreadable = []string{
	".aws",
	".netrc",
	filepath.Join(".docker", "config.json"),
	".kube",
	filepath.Join(".config", "gcloud"),
	".azure",
	".gnupg",
}

// readLimits are what a confined job may not read (real paths: the
// daemon's own directory and the Unreadable logins under the home) and,
// beneath them, what it still may: those of its own paths (p's Dir and
// Writable, writable), the launcher and Settings.Readable that are inside
// one. Paths that hold one of deny are never in allow, so allow can't undo
// deny.
func (c *confined) readLimits(p Proc, writable []string) (deny, allow []string) {
	cand := append([]string(nil), c.s.Protected...)
	if c.s.Home != "" {
		for _, u := range Unreadable {
			cand = append(cand, filepath.Join(c.s.Home, u))
		}
	}
	for _, d := range cand {
		d = realOrClean(d)
		if d == "" || filepath.Dir(d) == d {
			continue
		}
		deny = append(deny, d)
	}
	deny = outermost(deny)
	if len(deny) == 0 {
		return nil, nil
	}
	cand = append(append(append([]string{p.Dir}, p.Writable...), writable...), c.s.Readable...)
	if l := c.launcher(); l != "" {
		cand = append(cand, l)
	}
	seen := map[string]bool{}
	for _, a := range cand {
		a = realOrClean(a)
		if a == "" || seen[a] {
			continue
		}
		seen[a] = true
		inside, over := false, false
		for _, d := range deny {
			inside = inside || (a != d && holds(d, a))
			over = over || holds(a, d)
		}
		if inside && !over {
			allow = append(allow, a)
		}
	}
	return deny, allow
}

// realOrClean is path's real path, or, when it isn't there, its parent's
// real path and its name; "" when it isn't absolute.
func realOrClean(path string) string {
	if !filepath.IsAbs(path) {
		return ""
	}
	path = filepath.Clean(path)
	if r, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(r)
	}
	if r, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		return filepath.Join(r, filepath.Base(path))
	}
	return path
}

// outermost is paths without those inside another of them, sorted.
func outermost(paths []string) []string {
	sort.Strings(paths)
	var out []string
	for _, p := range paths {
		inside := false
		for _, o := range out {
			if holds(o, p) {
				inside = true
				break
			}
		}
		if !inside {
			out = append(out, p)
		}
	}
	return out
}

// holdsAny: path is one of paths or holds one.
func holdsAny(path string, paths []string) bool {
	for _, p := range paths {
		if holds(path, p) {
			return true
		}
	}
	return false
}

// readRules are what Landlock, which only allows, is told to let a job
// read so that it reads everything but deny (real paths, none inside
// another): each directory on the way to one of deny may be listed (dirs),
// and everything else in it read (others), but for symbolic links, whose
// targets are covered where they are. What appears later in one of dirs
// can't be read: the rules are on what is there when the job starts.
func readRules(deny []string) (dirs, others []string) {
	denied := map[string]bool{}
	onPath := map[string]bool{}
	for _, d := range deny {
		denied[d] = true
		for a := filepath.Dir(d); ; a = filepath.Dir(a) {
			onPath[a] = true
			if filepath.Dir(a) == a {
				break
			}
		}
	}
	var ancestors []string
	for a := range onPath {
		if !denied[a] {
			ancestors = append(ancestors, a)
		}
	}
	sort.Strings(ancestors)
	for _, a := range ancestors {
		fi, err := os.Stat(a)
		if err != nil || !fi.IsDir() {
			continue
		}
		dirs = append(dirs, a)
		entries, err := os.ReadDir(a)
		if err != nil {
			continue
		}
		for _, e := range entries {
			child := filepath.Join(a, e.Name())
			if onPath[child] || denied[child] || e.Type()&os.ModeSymlink != 0 {
				continue
			}
			others = append(others, child)
		}
	}
	return dirs, others
}
