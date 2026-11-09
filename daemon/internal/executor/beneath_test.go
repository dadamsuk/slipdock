//go:build go1.24 && !windows

package executor

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestBeneathReadsOnlyRegularFilesUnderItsRoot is the reader a container
// job's transcripts go through (#2625): what the job planted (a link out
// of the directory, to a file or to a directory, a link within it, a
// FIFO, a file too big, a path that isn't beneath it) is never read, nor
// waited on.
func TestBeneathReadsOnlyRegularFilesUnderItsRoot(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	host, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	write := func(path, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	link := func(target, path string) {
		t.Helper()
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
	}
	secret := filepath.Join(host, "secret.jsonl")
	write(secret, "the machine's secret\n")
	write(filepath.Join(host, "dir", "s.jsonl"), "the machine's secret\n")
	write(filepath.Join(root, "top.jsonl"), "top\n")
	write(filepath.Join(root, "proj", "s.jsonl"), "0123456789")
	write(filepath.Join(root, "proj", "big.jsonl"), "0123456789x")
	link(secret, filepath.Join(root, "proj", "out.jsonl"))
	link("../../"+filepath.Base(host)+"/secret.jsonl", filepath.Join(root, "proj", "rel.jsonl"))
	link("s.jsonl", filepath.Join(root, "proj", "in.jsonl"))
	link(filepath.Join(host, "dir"), filepath.Join(root, "linked"))
	link("proj", filepath.Join(root, "linkin"))
	if err := syscall.Mkfifo(filepath.Join(root, "proj", "fifo.jsonl"), 0o600); err != nil {
		t.Fatal(err)
	}

	f := Beneath(root, 10)
	if got := strings.Join(f.Glob(root, filepath.Join("*", "*.jsonl")), ","); got != filepath.Join(root, "proj", "big.jsonl")+","+filepath.Join(root, "proj", "s.jsonl") {
		t.Errorf("Glob */*.jsonl = %s: only the regular files, through real directories", got)
	}
	if got := f.Glob(root, "*.jsonl"); len(got) != 1 || got[0] != filepath.Join(root, "top.jsonl") {
		t.Errorf("Glob *.jsonl = %v", got)
	}
	if f.Glob(host, "*.jsonl") != nil || f.Glob(filepath.Join(root, "proj"), "*.jsonl") != nil {
		t.Error("Glob listed a directory other than its root")
	}

	if b, err := f.ReadFile(filepath.Join(root, "proj", "s.jsonl")); err != nil || string(b) != "0123456789" {
		t.Errorf("ReadFile = %q, %v: a file at the cap is read", b, err)
	}
	if b, err := f.ReadFile(filepath.Join(root, "top.jsonl")); err != nil || string(b) != "top\n" {
		t.Errorf("ReadFile = %q, %v", b, err)
	}
	refused := map[string]string{
		"a link to a file outside":        filepath.Join(root, "proj", "out.jsonl"),
		"a relative link out":             filepath.Join(root, "proj", "rel.jsonl"),
		"a link within":                   filepath.Join(root, "proj", "in.jsonl"),
		"through a link to a dir outside": filepath.Join(root, "linked", "s.jsonl"),
		"a file over the cap":             filepath.Join(root, "proj", "big.jsonl"),
		"a path outside":                  secret,
		"a path that climbs out":          filepath.Join(root, "proj", "..", "..", filepath.Base(host), "secret.jsonl"),
		"the root itself":                 root,
		"a directory":                     filepath.Join(root, "proj"),
		"a file that isn't there":         filepath.Join(root, "gone.jsonl"),
	}
	for what, path := range refused {
		if b, err := f.ReadFile(path); err == nil || strings.Contains(string(b), "secret") {
			t.Errorf("%s: read %q, %v", what, b, err)
		}
	}

	// A FIFO is refused without waiting for a writer, and never opened:
	// a writer waiting for a reader is still waiting after.
	fifo := filepath.Join(root, "proj", "fifo.jsonl")
	writer := make(chan struct{})
	go func() {
		if w, err := os.OpenFile(fifo, os.O_WRONLY, 0); err == nil {
			_ = w.Close()
		}
		close(writer)
	}()
	defer func() {
		// Let the writer go.
		if r, err := os.OpenFile(fifo, os.O_RDONLY|syscall.O_NONBLOCK, 0); err == nil {
			<-writer
			_ = r.Close()
		}
	}()
	time.Sleep(50 * time.Millisecond)
	done := make(chan error, 1)
	go func() {
		_, err := f.ReadFile(filepath.Join(root, "proj", "fifo.jsonl"))
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Error("read a FIFO")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("hung on a FIFO")
	}
	select {
	case <-writer:
		t.Error("opened the FIFO: its writer stopped waiting")
	case <-time.After(100 * time.Millisecond):
	}

	all := []string{filepath.Join(root, "proj", "s.jsonl"), filepath.Join(root, "proj", "out.jsonl"),
		filepath.Join(root, "proj", "fifo.jsonl"), filepath.Join(root, "linked", "s.jsonl"), secret}
	if got := f.Recent(all, time.Time{}); len(got) != 1 || got[0] != all[0] {
		t.Errorf("Recent = %v: only the regular file beneath the root", got)
	}
	if got := f.Recent(all[:1], time.Now().Add(time.Hour)); len(got) != 0 {
		t.Errorf("Recent = %v: nothing is newer than the future", got)
	}

	// The default cap, and a root that isn't there.
	if Beneath(root, 0).(beneath).max != BeneathMax || !BeneathReads {
		t.Error("the default cap")
	}
	gone := Beneath(filepath.Join(root, "gone"), 0)
	if gone.Glob(filepath.Join(root, "gone"), "*") != nil || gone.Recent(all, time.Time{}) != nil {
		t.Error("listed a root that isn't there")
	}
	if _, err := gone.ReadFile(filepath.Join(root, "gone", "x")); err == nil {
		t.Error("read under a root that isn't there")
	}
}

// TestBeneathHoldsWhenTheFileIsSwapped: a job can change a file between
// the reader's look at it and its open, or between the open and the read.
// Swapped for a FIFO, it isn't waited on; for a link, it isn't followed;
// grown past the cap, only the cap is read.
func TestBeneathHoldsWhenTheFileIsSwapped(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "inside"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	defer func() { swapped = nil }()
	path := filepath.Join(root, "s.jsonl")
	for what, swap := range map[string]func(){
		"a FIFO":            func() { _ = syscall.Mkfifo(path, 0o600) },
		"a link within":     func() { _ = os.Symlink("inside", path) },
		"a link outside":    func() { _ = os.Symlink(outside, path) },
		"a link up and out": func() { _ = os.Symlink("../"+filepath.Base(filepath.Dir(outside))+"/secret", path) },
	} {
		if err := os.WriteFile(path, []byte("ok\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		swapped = func(p string, opened bool) {
			if !opened && p == path {
				_ = os.Remove(p)
				swap()
			}
		}
		done := make(chan error, 1)
		go func() {
			b, err := Beneath(root, 0).ReadFile(path)
			if err == nil {
				err = fmt.Errorf("read %q", b)
			} else if len(b) > 0 {
				err = nil
			}
			done <- err
		}()
		select {
		case err := <-done:
			if err == nil || strings.HasPrefix(err.Error(), "read ") {
				t.Errorf("swapped for %s: %v", what, err)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("swapped for %s: hung", what)
		}
		_ = os.Remove(path)
	}

	// Grown past the cap once opened: only the cap is read.
	if err := os.WriteFile(path, []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	swapped = func(p string, opened bool) {
		if opened {
			f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
			_, _ = f.WriteString(strings.Repeat("x", 100))
			_ = f.Close()
		}
	}
	if b, err := Beneath(root, 10).ReadFile(path); err != nil || string(b) != "0123456789" {
		t.Errorf("grown past the cap: read %q, %v", b, err)
	}
}
