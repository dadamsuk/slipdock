package executor

import (
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
)

// ConfineMain is `slipdock-runner confine [--write PATH]... -- PROG
// [ARGS...]`, how the daemon starts a confined job on Linux: it takes
// away every write outside the paths (Landlock) and runs PROG in its
// place. Not for people: the daemon builds the command line.
func ConfineMain(args []string, stderr io.Writer) int {
	var writable []string
	i := 0
	for ; i < len(args); i++ {
		switch args[i] {
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
	err := confineExec(writable, prog, args[i+1:])
	// Only reached when it failed: the job never ran, unconfined or not.
	fmt.Fprintf(stderr, "slipdock-runner confine: the job was not run: %v\n", err)
	return 126
}
