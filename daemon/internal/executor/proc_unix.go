//go:build !windows

package executor

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

// inGroup starts cmd as the leader of a process group of its own, so the
// job and everything it starts can be signalled together.
func inGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// signalTree asks the job's process group to stop (TERM), or makes it
// (KILL, when force), then sweeps: the processes that left the group but
// carry the command's tag (see treeVar) get the same signal. A group
// already gone is not an error.
func signalTree(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	_ = syscall.Kill(-cmd.Process.Pid, sig)
	sweep(cmd, sig)
}

// sweep signals cmd's strays. Forced, it looks again until none is left
// (a stray may have been forking as it was listed), a few times at most.
func sweep(cmd *exec.Cmd, sig syscall.Signal) {
	tag := treeTag(cmd)
	if tag == "" {
		return
	}
	wt := ""
	if sweepsWorktree {
		wt = treeWorktree(cmd)
	}
	for round := 0; round < 3; round++ {
		pids := strays(ownProcs(tag, wt != ""), wt, os.Getpid())
		for _, pid := range pids {
			_ = syscall.Kill(pid, sig)
		}
		if len(pids) == 0 || sig != syscall.SIGKILL {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}
