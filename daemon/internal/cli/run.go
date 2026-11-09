package cli

import (
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/enrol"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// checkEvery is how often run asks the server whether the machine is still
// enrolled. A var so tests can shorten it.
var checkEvery = 5 * time.Minute

// cmdRun is what the service runs. For now it keeps the machine's
// enrolment checked and stops when the machine is revoked; running its
// runners' jobs is the next step (#2574).
func cmdRun(args []string, env Env) error {
	fs, home := newFlags("run", env)
	logPath := fs.String("log", "", "append the daemon's log to this file, not stderr")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	var w io.Writer = env.Stderr
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	logger := log.New(w, "slipdock-runner: ", log.LstdFlags)

	st, key, err := machine.Load(d)
	if err != nil {
		return err
	}
	if _, err := machine.LoadCeiling(d); err != nil {
		return fmt.Errorf("the ceiling: %w", err)
	}
	client := enrol.NewClient(st.Server, "slipdock-runner/"+Version)
	if env.HTTP != nil {
		client.HTTP = env.HTTP
	}
	sleep := client.Sleep
	if env.Sleep != nil {
		sleep = env.Sleep
	}
	ctx, cancel := env.Context()
	defer cancel()

	logger.Printf("%s %s starting as %s (machine #%d) on %s", "slipdock-runner", Version, st.Name, st.MachineID, st.Server)
	for {
		m, err := client.Me(ctx, key)
		switch {
		case enrol.IsUnauthorized(err) || (err == nil && m.State == "revoked"):
			return fmt.Errorf("the server no longer accepts this machine (revoked): run init --replace to enrol it again")
		case err != nil && ctx.Err() == nil:
			logger.Printf("can't reach the server, trying again: %v", err)
		case err == nil:
			logger.Printf("enrolled as %s, serving %s", m.Name, boardList(m.Boards))
		}
		if err := sleep(ctx, checkEvery); err != nil {
			logger.Printf("stopping")
			return nil
		}
	}
}
