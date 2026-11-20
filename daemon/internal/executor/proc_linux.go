package executor

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

// sweepsWorktree: on Linux every process's environment can be read, so
// the tag alone finds a job's strays.
const sweepsWorktree = false

// ownProcs are the daemon's account's processes, tagged when their
// environment carries tag. Linux reads /proc; the working directory isn't
// needed.
func ownProcs(tag string, _ bool) []liveProc {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	uid := os.Getuid()
	want := []byte(tag)
	var procs []liveProc
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		dir := filepath.Join("/proc", e.Name())
		fi, err := os.Stat(dir)
		if err != nil {
			continue
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != uid {
			continue
		}
		env, err := os.ReadFile(filepath.Join(dir, "environ"))
		if err != nil {
			continue
		}
		p := liveProc{pid: pid}
		for _, kv := range bytes.Split(env, []byte{0}) {
			if bytes.Equal(kv, want) {
				p.tagged = true
				break
			}
		}
		procs = append(procs, p)
	}
	return procs
}
