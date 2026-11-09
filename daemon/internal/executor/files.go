package executor

import (
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Files reads the files of the account jobs run as.
type Files interface {
	ReadFile(path string) ([]byte, error)
	// Glob is the paths under root matching pattern (filepath.Match's
	// syntax, with no spaces).
	Glob(root, pattern string) []string
	// Recent is the paths among paths modified since since, newest first.
	Recent(paths []string, since time.Time) []string
}

// LocalFiles are the daemon's own account's.
var LocalFiles Files = localFiles{}

type localFiles struct{}

func (localFiles) ReadFile(path string) ([]byte, error) { return os.ReadFile(path) }

func (localFiles) Glob(root, pattern string) []string {
	m, _ := filepath.Glob(filepath.Join(root, pattern))
	return m
}

func (localFiles) Recent(paths []string, since time.Time) []string {
	type file struct {
		path string
		mod  time.Time
	}
	var fresh []file
	for _, p := range paths {
		if fi, err := os.Stat(p); err == nil && !fi.ModTime().Before(since) {
			fresh = append(fresh, file{p, fi.ModTime()})
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].mod.After(fresh[j].mod) })
	out := make([]string, len(fresh))
	for i, f := range fresh {
		out[i] = f.path
	}
	return out
}
