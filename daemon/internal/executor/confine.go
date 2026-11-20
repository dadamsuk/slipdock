package executor

import (
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strconv"
)

// confinement is what `slipdock-runner confine` restricts a job to: the
// paths it may write, those it may not read (deny) and, beneath them,
// those it still may (read), and the ports it may connect to.
type confinement struct {
	write, deny, read []string
	connect           []int
}

// ConfineMain is `slipdock-runner confine [--write PATH]... [--deny-read
// PATH]... [--read PATH]... [--connect PORT]... -- PROG [ARGS...]`, how
// the daemon starts a confined job on Linux: it takes away every write
// outside the --write paths (Landlock), every read of the --deny-read
// paths but the --read ones beneath them, and, with --connect (a network
// allowlist, #3517), every TCP connection but to those ports, and runs
// PROG in its place. Not for people: the daemon builds the command line.
func ConfineMain(args []string, stderr io.Writer) int {
	var c confinement
	i := 0
	for ; i < len(args); i++ {
		switch args[i] {
		case "--write", "--deny-read", "--read":
			if i+1 >= len(args) || (args[i] != "--write" && !filepath.IsAbs(args[i+1])) {
				fmt.Fprintf(stderr, "slipdock-runner confine: %s needs a path\n", args[i])
				return 2
			}
			list := map[string]*[]string{"--write": &c.write, "--deny-read": &c.deny, "--read": &c.read}[args[i]]
			i++
			*list = append(*list, args[i])
			continue
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
			c.connect = append(c.connect, port)
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
		fmt.Fprintln(stderr, "usage: slipdock-runner confine [--write PATH]... [--deny-read PATH]... [--read PATH]... [--connect PORT]... -- PROG [ARGS...]")
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
	err := confineExec(c, prog, args[i+1:])
	// Only reached when it failed: the job never ran, unconfined or not.
	fmt.Fprintf(stderr, "slipdock-runner confine: the job was not run: %v\n", err)
	return 126
}
