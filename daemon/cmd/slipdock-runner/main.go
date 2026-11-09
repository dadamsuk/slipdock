// Command slipdock-runner is the Slipdock runner daemon: one per machine,
// running that machine's runners (W-2540). This is only its entry point; the
// commands are in internal/cli.
package main

import (
	"os"

	"github.com/dadamsuk/slipdock/daemon/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], cli.DefaultEnv()))
}
