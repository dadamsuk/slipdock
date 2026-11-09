//go:build !windows

package runner

import (
	"os/exec"
	"syscall"
)

// inGroup starts cmd as the leader of a process group of its own, so the
// job and everything it starts can be signalled together.
func inGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// signalTree asks the job's process group to stop (TERM), or makes it
// (KILL, when force). A group already gone is not an error.
func signalTree(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	_ = syscall.Kill(-cmd.Process.Pid, sig)
}
