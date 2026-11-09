//go:build go1.24 && !windows

package executor

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// BeneathMax is the most of one file Beneath reads: a bigger one is
// refused rather than read into memory.
const BeneathMax = 128 << 20

// Beneath reads only regular files beneath root (#2625): a container
// job's transcripts, in the directory made for them and mounted into its
// container, which the job can write anything into. Every open goes
// through an os.Root, so no link or ".." leads out of root; a link inside
// it isn't followed either (what is opened must be the regular file
// looked at). A FIFO, a device or a socket is never opened,
// and a file is opened non-blocking so one swapped in can't hang the
// daemon. A file over max (BeneathMax when 0) is refused. Paths are
// root's, as Glob gives them; one outside root is refused.
func Beneath(root string, max int64) Files {
	if max <= 0 {
		max = BeneathMax
	}
	return beneath{root: filepath.Clean(root), max: max}
}

// swapped, in tests, runs where a job could change a file under
// ReadFile: between its look at it and its open (opened false), and
// between the open's look and the read (opened true).
var swapped func(path string, opened bool)

type beneath struct {
	root string
	max  int64
}

// rel is path relative to root, or an error when it isn't beneath it.
func (b beneath) rel(path string) (string, error) {
	rel, err := filepath.Rel(b.root, filepath.Clean(path))
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", fmt.Errorf("%s: not beneath %s", path, b.root)
	}
	return rel, nil
}

func (b beneath) ReadFile(path string) ([]byte, error) {
	rel, err := b.rel(path)
	if err != nil {
		return nil, err
	}
	r, err := os.OpenRoot(b.root)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	// Looked at first, without following a link: only a regular file is
	// opened at all.
	seen, err := r.Lstat(rel)
	if err != nil {
		return nil, err
	}
	if !seen.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file", path)
	}
	if swapped != nil {
		swapped(filepath.Join(b.root, rel), false)
	}
	// Swapped since for a FIFO, the open doesn't wait for a writer.
	f, err := r.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	// And what was opened must be what was looked at: os.Root follows a
	// link that stays beneath it, and the file may have been swapped.
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() || !os.SameFile(seen, fi) {
		return nil, fmt.Errorf("%s: not a regular file", path)
	}
	if fi.Size() > b.max {
		return nil, fmt.Errorf("%s: over %d bytes", path, b.max)
	}
	if swapped != nil {
		swapped(filepath.Join(b.root, rel), true)
	}
	// One growing since is read only up to the cap.
	return io.ReadAll(io.LimitReader(f, b.max))
}

// Glob is the regular files beneath root matching pattern, a name or
// dir/name pattern, through real directories only.
func (b beneath) Glob(root, pattern string) []string {
	if filepath.Clean(root) != b.root {
		return nil
	}
	r, err := os.OpenRoot(b.root)
	if err != nil {
		return nil
	}
	defer r.Close()
	parts := strings.Split(filepath.ToSlash(pattern), "/")
	var out []string
	var walk func(dir string, parts []string)
	walk = func(dir string, parts []string) {
		entries, err := readDir(r, dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			if ok, _ := filepath.Match(parts[0], e.Name()); !ok {
				continue
			}
			rel := filepath.Join(dir, e.Name())
			switch {
			case len(parts) > 1 && e.Type().IsDir():
				walk(rel, parts[1:])
			case len(parts) == 1 && e.Type().IsRegular():
				out = append(out, filepath.Join(b.root, rel))
			}
		}
	}
	walk(".", parts)
	return out
}

// readDir lists dir beneath r; its entries' types are their own, links
// not followed.
func readDir(r *os.Root, dir string) ([]fs.DirEntry, error) {
	d, err := r.Open(dir)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	entries, err := d.ReadDir(-1)
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	return entries, err
}

func (b beneath) Recent(paths []string, since time.Time) []string {
	r, err := os.OpenRoot(b.root)
	if err != nil {
		return nil
	}
	defer r.Close()
	type file struct {
		path string
		mod  time.Time
	}
	var fresh []file
	for _, p := range paths {
		rel, err := b.rel(p)
		if err != nil {
			continue
		}
		if fi, err := r.Lstat(rel); err == nil && fi.Mode().IsRegular() && !fi.ModTime().Before(since) {
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

// BeneathReads says whether this build reads a container job's
// transcripts (Beneath needs Go 1.24's os.Root).
const BeneathReads = true
