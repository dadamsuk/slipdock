package executor

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// A job's processes are stopped by their process group, but a process can
// leave the group: setsid, a double fork, a daemon. So every process a job
// starts carries a tag in its environment (#3490), SLIPDOCK_TREE=<random>,
// fresh for each command the executor makes, which its children inherit
// whatever group or session they move to. Stopping the command signals its
// group, then sweeps: every process of the account jobs run as that
// carries the command's tag is signalled too.
//
//   - Linux: the tag, read from /proc/<pid>/environ (the daemon's own
//     account's processes; the user executor's, read as its account).
//   - macOS: the tag, read with `ps -E`. macOS hides the environment of
//     its own programs (/bin/sh, /bin/sleep and the like) from ps, so a
//     job in a worktree also loses every process of the account with no
//     terminal whose working directory is in the worktree (read with
//     lsof). A process of a person's, at a terminal, is never taken.
//
// What escapes: a process that clears its environment (env -i) and, on
// macOS, isn't in the job's worktree or is one of Apple's programs outside
// it; and anything that runs as another account. A container job's
// processes are the container runtime's to stop (it kills the whole
// container), so they carry no tag. On Windows, taskkill /T stops the
// tree by its parent links, and a process whose parent has gone escapes.
const treeVar = "SLIPDOCK_TREE"

// newTreeTag is a fresh tag: the variable and its value, as an
// environment has it.
func newTreeTag() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%s=t%d", treeVar, time.Now().UnixNano())
	}
	return treeVar + "=" + hex.EncodeToString(b)
}

// mark tags cmd's tree: the tag goes last, so that it wins over any the
// job's own variables carry.
func mark(cmd *exec.Cmd) {
	cmd.Env = append(cmd.Env, newTreeTag())
}

// lastWith is the last of list that starts with prefix, or "".
func lastWith(list []string, prefix string) string {
	for i := len(list) - 1; i >= 0; i-- {
		if strings.HasPrefix(list[i], prefix) {
			return list[i]
		}
	}
	return ""
}

// treeTag is the tag cmd's processes carry, or "" when it has none.
func treeTag(cmd *exec.Cmd) string { return lastWith(cmd.Env, treeVar+"=") }

// treeWorktree is the job's worktree, when cmd is a job's in one: the
// directory whose processes are the job's on macOS.
func treeWorktree(cmd *exec.Cmd) string {
	wt := strings.TrimPrefix(lastWith(cmd.Env, "SLIPDOCK_WORKTREE="), "SLIPDOCK_WORKTREE=")
	if wt == "" || !filepath.IsAbs(wt) {
		return ""
	}
	if real, err := filepath.EvalSymlinks(wt); err == nil {
		return real
	}
	return filepath.Clean(wt)
}

// liveProc is what a sweep knows of one of the account's processes.
type liveProc struct {
	pid    int
	tagged bool   // its environment carries the tag
	tty    bool   // it has a controlling terminal: a person's
	cwd    string // its working directory, when read
}

// strays are the processes a sweep signals: those that carry the tag, and,
// when worktree is set, those with no terminal working in it. Never pid 1
// or self (the daemon).
func strays(procs []liveProc, worktree string, self int) []int {
	var out []int
	for _, p := range procs {
		if p.pid <= 1 || p.pid == self {
			continue
		}
		if p.tagged || (worktree != "" && !p.tty && within(p.cwd, worktree)) {
			out = append(out, p.pid)
		}
	}
	sort.Ints(out)
	return out
}

// within says whether path is dir or beneath it.
func within(path, dir string) bool {
	if path == "" || dir == "" {
		return false
	}
	dir = strings.TrimSuffix(dir, "/")
	if dir == "" {
		return false
	}
	return path == dir || strings.HasPrefix(path, dir+"/")
}

// psProcs reads `ps -E -ww -x -o pid=,tty=,command=` (macOS): each line
// the pid, the terminal (?? for none), then the command line and, where
// macOS shows it, the environment. A word that is exactly the tag tags it.
func psProcs(out, tag string) []liveProc {
	var procs []liveProc
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		pid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		p := liveProc{pid: pid, tty: f[1] != "??" && f[1] != "-"}
		for _, w := range f[2:] {
			if tag != "" && w == tag {
				p.tagged = true
				break
			}
		}
		procs = append(procs, p)
	}
	return procs
}

// lsofCwds reads `lsof -Fpn -d cwd`: a p line names a process, the n line
// after it its working directory.
func lsofCwds(out string) map[int]string {
	cwds := map[int]string{}
	pid := 0
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "p"):
			pid, _ = strconv.Atoi(line[1:])
		case strings.HasPrefix(line, "n") && pid > 0:
			cwds[pid] = line[1:]
		}
	}
	return cwds
}

// environPids reads the paths `grep -l` printed of /proc/<pid>/environ:
// the pids.
func environPids(out string) []int {
	var pids []int
	for _, line := range strings.Split(out, "\n") {
		rest, ok := strings.CutPrefix(strings.TrimSpace(line), "/proc/")
		if !ok {
			continue
		}
		if pid, err := strconv.Atoi(strings.TrimSuffix(rest, "/environ")); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}
