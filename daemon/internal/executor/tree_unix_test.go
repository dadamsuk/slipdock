//go:build !windows

package executor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func init() {
	helpers["helper-tick"] = helperTick
	helpers["helper-escape"] = helperEscape
}

// helperTick writes a count into args[0] every 20ms, for an hour at most:
// a process that is running ticks.
func helperTick(args []string) int {
	_ = os.WriteFile(args[0]+".pid", []byte(strconv.Itoa(os.Getpid())), 0o600)
	for i := 0; i < 180000; i++ {
		_ = os.WriteFile(args[0], []byte(strconv.Itoa(i)), 0o600)
		time.Sleep(20 * time.Millisecond)
	}
	return 0
}

// helperEscape is a job whose children leave its process group, each in
// a session of its own, ticking in args[0]: "tagged" with the job's
// environment, "bare" with none at all. Then it waits.
func helperEscape(args []string) int {
	dir := args[0]
	for _, name := range []string{"tagged", "bare"} {
		c := exec.Command(os.Args[0], "helper-tick", filepath.Join(dir, name))
		c.Dir = dir
		c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if name == "bare" {
			c.Env = []string{}
		}
		if err := c.Start(); err != nil {
			fmt.Println(name, err)
			return 1
		}
	}
	time.Sleep(time.Hour)
	return 0
}

// ticks says whether the process ticking in path still runs.
func ticks(path string) bool {
	before, _ := os.ReadFile(path)
	time.Sleep(300 * time.Millisecond)
	after, _ := os.ReadFile(path)
	return len(after) > 0 && string(before) != string(after)
}

// killTicker kills the process ticking in path, if it is there.
func killTicker(path string) {
	if data, err := os.ReadFile(path + ".pid"); err == nil {
		if pid, err := strconv.Atoi(string(data)); err == nil && pid > 1 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}

// Stopping a job reaches the processes that left its group (#3490): by
// its tag everywhere, and on macOS by working in its worktree. Another
// job's processes, with a tag of their own, are left alone.
func TestStoppingAJobStopsWhatLeftItsGroup(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	other, _ := filepath.EvalSymlinks(t.TempDir())
	tagged, bare, neighbour := filepath.Join(dir, "tagged"), filepath.Join(dir, "bare"), filepath.Join(other, "neighbour")
	t.Cleanup(func() {
		for _, p := range []string{tagged, bare, neighbour} {
			killTicker(p)
		}
	})
	ex, err := New(Me, Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Fatal(err)
	}
	nb, _ := ex.Command(Proc{Dir: other, Env: []string{"SLIPDOCK_WORKTREE=" + other}}, os.Args[0], "helper-tick", neighbour)
	if err := nb.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { _ = nb.Wait() }()
	t.Cleanup(func() { ex.Stop(nb, true) })

	cmd, _ := ex.Command(Proc{Dir: dir, Env: []string{"SLIPDOCK_WORKTREE=" + dir}}, os.Args[0], "helper-escape", dir)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	waitUntil(t, func() bool {
		for _, p := range []string{tagged, bare, neighbour} {
			if _, err := os.Stat(p); err != nil {
				return false
			}
		}
		return true
	})
	if !ticks(tagged) || !ticks(bare) {
		t.Fatal("the children aren't ticking: the test proves nothing")
	}
	ex.Stop(cmd, false)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
	}
	ex.Stop(cmd, true)

	if ticks(tagged) {
		t.Error("a child in a session of its own, with the job's tag, outlived the stop")
	}
	switch runtime.GOOS {
	case "darwin":
		if ticks(bare) {
			t.Error("macOS: a child with no environment, working in the worktree, outlived the stop")
		}
	case "linux":
		// The tag alone: a process that clears its environment escapes.
		if !ticks(bare) {
			t.Error("Linux: a child with no tag was stopped: the sweep reached beyond the job's tag")
		}
	}
	if !ticks(neighbour) {
		t.Error("another job's process was stopped")
	}
}
