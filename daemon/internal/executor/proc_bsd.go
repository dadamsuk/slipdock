//go:build !linux && !windows

package executor

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// sweepsWorktree: macOS hides its own programs' environment from ps, so
// a job in a worktree also loses what works in it (see treeVar).
const sweepsWorktree = true

// ownProcs are the daemon's account's processes, read with ps -E, tagged
// when their environment carries tag; with cwds, lsof reads the working
// directory of those that are neither tagged nor at a terminal.
func ownProcs(tag string, cwds bool) []liveProc {
	out, err := exec.Command("/bin/ps", "-E", "-ww", "-x", "-o", "pid=,tty=,command=").Output()
	if err != nil {
		return nil
	}
	procs := psProcs(string(out), tag)
	if !cwds {
		return procs
	}
	var ask []string
	for _, p := range procs {
		if !p.tagged && !p.tty && p.pid > 1 && p.pid != os.Getpid() {
			ask = append(ask, strconv.Itoa(p.pid))
		}
	}
	if len(ask) == 0 {
		return procs
	}
	// -a: every condition at once; -w: no warnings. lsof exits 1 when a
	// pid has gone meanwhile, and still prints the rest.
	lsof, _ := exec.Command("/usr/sbin/lsof", "-a", "-w", "-d", "cwd", "-Fpn", "-u", strconv.Itoa(os.Getuid()),
		"-p", strings.Join(ask, ",")).Output()
	dirs := lsofCwds(string(lsof))
	for i := range procs {
		procs[i].cwd = dirs[procs[i].pid]
	}
	return procs
}
