package executor

import (
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strconv"
)

// ConfineMain is `slipdock-runner confine [--write PATH]... [--connect
// PORT]... -- PROG [ARGS...]`, how the daemon starts a confined job on
// Linux: it takes away every write outside the paths (Landlock) and, with
// --connect (a network allowlist, #3517), every TCP connection but to
// those ports, and runs PROG in its place. Not for people: the daemon
// builds the command line.
func ConfineMain(args []string, stderr io.Writer) int {
	var writable []string
	var connect []int
	i := 0
	for ; i < len(args); i++ {
		switch args[i] {
		case "--connect":
			var port int
			if i+1 < len(args) {
				port, _ = strconv.Atoi(args[i+1])
			}
			if port < 1 || port > 65535 {
				fmt.Fprintln(stderr, "slipdock-runner confine: --connect needs a port")
				return 2
			}
			i++
			connect = append(connect, port)
			continue
		case "--write":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "slipdock-runner confine: --write needs a path")
				return 2
			}
			i++
			writable = append(writable, args[i])
			continue
		case "--":
			i++
		default:
			fmt.Fprintf(stderr, "slipdock-runner confine: unexpected %q\n", args[i])
			return 2
		}
		break
	}
	if i >= len(args) {
		fmt.Fprintln(stderr, "usage: slipdock-runner confine [--write PATH]... -- PROG [ARGS...]")
		return 2
	}
	prog := args[i]
	if !filepath.IsAbs(prog) {
		p, err := exec.LookPath(prog)
		if err != nil {
			fmt.Fprintf(stderr, "slipdock-runner confine: %v\n", err)
			return 127
		}
		prog = p
	}
	err := confineExec(writable, connect, prog, args[i+1:])
	// Only reached when it failed: the job never ran, unconfined or not.
	fmt.Fprintf(stderr, "slipdock-runner confine: the job was not run: %v\n", err)
	return 126
}
