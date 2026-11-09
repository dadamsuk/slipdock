package cli

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/contract"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// cmdShow prints the trust contract filled with this machine's limits.
func cmdShow(args []string, env Env) error {
	fs, home := newFlags("show", env)
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	st, _, err := machine.Load(d)
	if err != nil {
		return err
	}
	c, err := machine.LoadCeiling(d)
	if err != nil {
		return fmt.Errorf("the ceiling: %w", err)
	}
	id, err := machine.LoadOrCreateIdentity(d)
	if err != nil {
		return err
	}
	if err := contract.Render(env.Stdout, contract.Facts{
		Server:      st.Server,
		Name:        st.Name,
		MachineID:   st.MachineID,
		Fingerprint: id.Fingerprint(),
		Version:     Version,
		Account:     env.Account() + " (the account the daemon runs as)",
		CeilingPath: filepath.Join(d, machine.CeilingFile),
		KeyPath:     filepath.Join(d, machine.KeyFile),
		Ceiling:     c,
	}); err != nil {
		return err
	}
	return showUpdates(d, env)
}

// showUpdates says how this binary is kept current, and how the last check went.
func showUpdates(d string, env Env) error {
	mode, last, err := updateLines(d)
	if err != nil {
		return err
	}
	fmt.Fprintf(env.Stdout, "\nUpdates:       %s. An update installs only if it is signed\n", mode)
	fmt.Fprintln(env.Stdout, "               with the project's release key, which is built into this binary.")
	if last != nil {
		line := fmt.Sprintf("%s at %s", last.Outcome, last.At.Format(time.RFC3339))
		if last.Latest != "" {
			line += ", latest " + last.Latest
		}
		if last.Reason != "" {
			line += ": " + last.Reason
		}
		fmt.Fprintf(env.Stdout, "Last check:    %s\n", line)
	}
	return nil
}
