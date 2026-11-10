//go:build !windows

package cli

import (
	"errors"
	"os"
	"syscall"
)

// processAlive says whether a process with this pid is running: signal 0
// checks without sending anything, and EPERM is a process of another
// account's, which is running.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = p.Signal(syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}
