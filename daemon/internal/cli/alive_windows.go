//go:build windows

package cli

import "os"

// processAlive says whether a process with this pid is running: on
// Windows, FindProcess opens the process and fails when there is none.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	p.Release()
	return true
}
