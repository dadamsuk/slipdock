package cli

import (
	"fmt"
	"path/filepath"

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
	return contract.Render(env.Stdout, contract.Facts{
		Server:      st.Server,
		Name:        st.Name,
		MachineID:   st.MachineID,
		Fingerprint: id.Fingerprint(),
		Version:     Version,
		Account:     env.Account() + " (the account the daemon runs as)",
		CeilingPath: filepath.Join(d, machine.CeilingFile),
		KeyPath:     filepath.Join(d, machine.KeyFile),
		Ceiling:     c,
	})
}
