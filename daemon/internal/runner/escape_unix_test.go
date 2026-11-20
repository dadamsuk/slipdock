//go:build !windows

package runner

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func init() {
	helpers["escaping-tree"] = escapingTree
	helpers["daemonize"] = daemonize
}

// escapingTree is a job whose children leave its process group: one in a
// session of its own (setsid), ticking into $HELPER_TICK, and one that
// daemonizes (a double fork: its own child, in a session of its own,
// ticks into $HELPER_TICK2 after it has gone, so its parent is init's).
// Then it waits.
func escapingTree([]string) int {
	setsid := exec.Command(os.Args[0], "helper", "tick")
	setsid.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := setsid.Start(); err != nil {
		fmt.Println("setsid:", err)
		return 1
	}
	_ = os.WriteFile(os.Getenv("HELPER_TICK")+".pid", []byte(strconv.Itoa(setsid.Process.Pid)), 0o600)
	if err := exec.Command(os.Args[0], "helper", "daemonize").Run(); err != nil {
		fmt.Println("daemonize:", err)
		return 1
	}
	fmt.Println("started the escaping tree")
	time.Sleep(time.Hour)
	return 0
}

// daemonize starts its child in a session of its own, ticking into
// $HELPER_TICK2, and exits at once.
func daemonize([]string) int {
	c := exec.Command(os.Args[0], "helper", "tick")
	c.Env = append(os.Environ(), "HELPER_TICK="+os.Getenv("HELPER_TICK2"))
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return 1
	}
	_ = os.WriteFile(os.Getenv("HELPER_TICK2")+".pid", []byte(strconv.Itoa(c.Process.Pid)), 0o600)
	return 0
}

// Cancel from the board stops the processes that left the job's group
// (#3490): a setsid child and a daemon whose parent has gone.
func TestCancelStopsWhatLeftTheJobsGroup(t *testing.T) {
	r, tick := treeRig(t, Config{})
	r.w.Local.Agents["claude"] = self("escaping-tree")
	tick2 := filepath.Join(t.TempDir(), "tick2")
	t.Setenv("HELPER_TICK2", tick2)
	t.Cleanup(func() {
		// Whatever outlived a failure.
		for _, p := range []string{tick, tick2} {
			if data, err := os.ReadFile(p + ".pid"); err == nil {
				if pid, _ := strconv.Atoi(string(data)); pid > 1 {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			}
		}
	})
	r.srv.add(fakeJob{runner: 11, id: 125, kind: "claude", card: 7, prompt: "x"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.w.Run(ctx)
	waitFor(t, "both children to tick", func() bool {
		_, a := os.Stat(tick)
		_, b := os.Stat(tick2)
		return a == nil && b == nil
	})
	waitFor(t, "a heartbeat with the log", func() bool {
		r.srv.mu.Lock()
		defer r.srv.mu.Unlock()
		b := r.srv.beats[125]
		return len(b) > 0 && strings.Contains(b[len(b)-1], "started the escaping tree")
	})
	// Waited for, not sampled: a loaded machine can stall a child for
	// longer than ticking looks.
	for _, p := range []string{tick, tick2} {
		before, _ := os.ReadFile(p)
		waitFor(t, "the child ticking into "+filepath.Base(p), func() bool {
			after, _ := os.ReadFile(p)
			return len(after) > 0 && string(after) != string(before)
		})
	}
	r.srv.mu.Lock()
	r.srv.cancel[125] = true
	r.srv.mu.Unlock()
	waitFor(t, "the finish", func() bool { _, ok := r.srv.finish(125); return ok })
	f, _ := r.srv.finish(125)
	if f.exit != 130 || f.status != "cancelled" {
		t.Fatalf("finish = %+v", f)
	}
	if ticking(t, tick) {
		t.Error("a child in a session of its own (setsid) outlived the cancel")
	}
	if ticking(t, tick2) {
		t.Error("a daemonized grandchild outlived the cancel")
	}
}
