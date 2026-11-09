//go:build windows

package runner

import (
	"os/exec"
	"strconv"
	"syscall"
)

// inGroup starts cmd in a process group of its own, apart from the
// daemon's console.
func inGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// signalTree stops the job and every process it started: taskkill /T walks
// the tree from the job's process. Windows has no polite signal for a
// console program in another group, so both asks are the same.
func signalTree(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	kill := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
	_ = kill.Run()
	if force {
		_ = cmd.Process.Kill()
	}
}
