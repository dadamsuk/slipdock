package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/service"
)

// cmdService installs, removes or prints the daemon's service.
func cmdService(args []string, env Env) error {
	if len(args) == 0 {
		fmt.Fprintln(env.Stderr, "slipdock-runner service install|uninstall|print [--home DIR]")
		return errUsage
	}
	action, rest := args[0], args[1:]
	fs, home := newFlags("service "+action, env)
	if err := parse(fs, rest); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	spec, err := serviceSpec(d, env)
	if err != nil {
		return err
	}
	plan, err := service.Build(spec)
	if err != nil {
		return err
	}
	switch action {
	case "print":
		fmt.Fprintf(env.Stdout, "# %s\n", plan.Path)
		if plan.Kind == service.Windows {
			// The file itself is UTF-16; the rest of the plan says what it holds.
			fmt.Fprintln(env.Stdout, "# (a Task Scheduler task, written as UTF-16)")
		} else {
			fmt.Fprint(env.Stdout, string(plan.Content))
		}
		return nil
	case "install":
		if !machine.Enrolled(d) {
			return machine.ErrNotEnrolled
		}
		if err := service.Install(plan, writeMkdir, env.Run); err != nil {
			return err
		}
		fmt.Fprintf(env.Stdout, "Installed and started: %s\nLogs: %s\n", plan.Path, plan.Logs)
		if plan.Note != "" {
			fmt.Fprintln(env.Stdout, plan.Note)
		}
		return nil
	case "uninstall":
		if err := service.Uninstall(plan, env.Run); err != nil {
			return err
		}
		if err := os.Remove(plan.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		fmt.Fprintf(env.Stdout, "Stopped and removed: %s\n", plan.Path)
		return nil
	default:
		fmt.Fprintf(env.Stderr, "slipdock-runner service: unknown action %q (install, uninstall or print)\n", action)
		return errUsage
	}
}

// serviceSpec describes this machine's service.
func serviceSpec(d string, env Env) (service.Spec, error) {
	_, lookErr := env.LookPath("systemctl")
	kind, err := service.Detect(env.GOOS, lookErr == nil)
	if err != nil {
		return service.Spec{}, err
	}
	exe, err := env.Executable()
	if err != nil {
		return service.Spec{}, fmt.Errorf("can't tell where this program is: %w", err)
	}
	userHome, err := env.UserHome()
	if err != nil {
		return service.Spec{}, err
	}
	configHome := env.Getenv("XDG_CONFIG_HOME")
	if configHome == "" {
		configHome = filepath.Join(userHome, ".config")
	}
	return service.Spec{
		Kind:       kind,
		Exe:        exe,
		Home:       d,
		UserHome:   userHome,
		ConfigHome: configHome,
		User:       env.Account(),
	}, nil
}

func writeMkdir(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
