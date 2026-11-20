//go:build linux

package executor

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// onItsOwnThread runs f on a thread of its own that ends with it, so
// whatever f makes Landlock restrict never reaches the rest of the tests.
func onItsOwnThread(f func() error) error {
	done := make(chan error, 1)
	go func() {
		runtime.LockOSThread() // never unlocked: the thread ends with the goroutine
		done <- f()
	}()
	return <-done
}

func TestAnAllowlistUnderAnOldLandlockIsRefusedBeforeAnythingRuns(t *testing.T) {
	defer func(f func() int) { landlockABI = f }(landlockABI)
	landlockABI = func() int { return 3 }
	err := onItsOwnThread(func() error { return restrict(nil, []int{4100}) })
	if err == nil || !strings.Contains(err.Error(), "a network allowlist needs 4") {
		t.Fatalf("restrict at ABI 3 with ports: %v", err)
	}
	// confineExec stops there too: the program is never run.
	missing := filepath.Join(t.TempDir(), "missing")
	err = onItsOwnThread(func() error { return confineExec(nil, []int{4100}, missing, nil) })
	if err == nil || !strings.Contains(err.Error(), "a network allowlist needs 4") {
		t.Fatalf("confineExec at ABI 3 with ports: %v", err)
	}
}

func TestAPortLandlockRefusesStopsTheRestriction(t *testing.T) {
	if abi := landlockABI(); abi < landlockNetABI {
		t.Skipf("this kernel's Landlock is ABI %d", abi)
	}
	err := onItsOwnThread(func() error { return restrict(nil, []int{70000}) })
	if err == nil || !strings.Contains(err.Error(), "landlock_add_rule port 70000") {
		t.Fatalf("restrict with port 70000: %v", err)
	}
}
