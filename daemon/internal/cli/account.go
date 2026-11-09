package cli

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// DefaultAccount is the dedicated account init offers.
const DefaultAccount = "slipdock"

// runAs is who init's choice says jobs run as.
type runAs struct {
	// account is the dedicated account's name, or "" for the person
	// running init (executor me, with confined where it exists).
	account string
	home    string // the account's home, once it is set up
}

func (r runAs) executors(goos string) []string {
	if r.account != "" {
		return []string{executor.User}
	}
	return executor.Offered(goos, false)
}

// chooseRunAs is --as-me or --user, else the question. Windows offers the
// current account only, and says so.
func chooseRunAs(asMe bool, user string, env Env) (runAs, error) {
	me := env.Account()
	if asMe && user != "" {
		fmt.Fprintln(env.Stderr, "slipdock-runner init: --as-me and --user are each other's opposite: give one")
		return runAs{}, errUsage
	}
	if env.GOOS == "windows" {
		if user != "" {
			return runAs{}, errors.New("on Windows jobs run as the current account only: a dedicated account isn't offered there yet")
		}
		fmt.Fprintf(env.Stdout, "On Windows jobs run as you (%s), the current account: a dedicated account isn't offered there yet.\n\n", me)
		return runAs{}, nil
	}
	switch {
	case asMe:
		return runAs{}, nil
	case user != "":
		return runAs{account: user}, nil
	}
	fmt.Fprintf(env.Stdout, "Who should jobs run as?\n\n"+
		"  1) A dedicated account, %[1]s. Recommended for an always-on machine (a build box, a WSL instance).\n"+
		"     %[2]s\n"+
		"     Setting it up takes one sudo.\n"+
		"  2) You, %[3]s. For a laptop that is only yours.\n"+
		"     %[4]s\n\n"+
		"Choose 1 or 2 [1]: ", DefaultAccount, executor.Limits[executor.User], me, executor.Limits[executor.Me])
	answer := strings.TrimSpace(readLine(env.Stdin))
	fmt.Fprintln(env.Stdout)
	switch answer {
	case "", "1":
		return runAs{account: DefaultAccount}, nil
	case "2":
		return runAs{}, nil
	}
	return runAs{}, fmt.Errorf("%q is not 1 or 2: run init again, or give --user NAME or --as-me", answer)
}

// setUpAccount runs the account's set-up with one sudo: the account, its
// sudoers rule, and the person's home closed to it (asked first).
func setUpAccount(r runAs, env Env) (runAs, error) {
	home, err := env.UserHome()
	if err != nil {
		return r, fmt.Errorf("can't find your home directory: %w", err)
	}
	closeHome := false
	if env.HomeOpen != nil && env.HomeOpen(home) {
		fmt.Fprintf(env.Stdout, "Your home %s is open to other accounts, so a job as %s could read it.\n"+
			"Close it (chmod o-rwx%s)? [Y/n]: ", home, r.account, map[bool]string{true: ", g-rwx"}[env.GOOS == "darwin"])
		answer := strings.ToLower(strings.TrimSpace(readLine(env.Stdin)))
		fmt.Fprintln(env.Stdout)
		if answer != "" && answer != "y" && answer != "yes" {
			return r, errors.New("the user executor needs your home closed to the account: close it, or run init with --as-me")
		}
		closeHome = true
	}
	script, err := executor.AccountSetupScript(env.GOOS, r.account, env.Account(), home, closeHome)
	if err != nil {
		return r, err
	}
	fmt.Fprintf(env.Stdout, "Setting up the account %s with sudo: it is made if it isn't there, and you may then run commands as it without a password (%s).\n",
		r.account, executor.SudoersFile(r.account))
	out, err := env.Output("sudo", "sh", "-c", script)
	if err != nil {
		return r, fmt.Errorf("setting up the account %s failed: %v %s", r.account, err, strings.TrimSpace(out))
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	r.home = strings.TrimSpace(lines[len(lines)-1])
	if !strings.HasPrefix(r.home, "/") {
		return r, fmt.Errorf("setting up the account %s didn't say where its home is: %s", r.account, strings.TrimSpace(out))
	}
	return r, nil
}

// saveRunAs writes the account into the local file, keeping the rest.
func saveRunAs(d string, r runAs) error {
	l, err := machine.LoadLocal(d)
	if err != nil {
		return err
	}
	if r.account == "" {
		l.User = nil
	} else {
		l.User = &machine.Account{Name: r.account, Home: r.home}
	}
	return machine.SaveLocal(d, l)
}

// startSetUp opens a login shell as the account, where the person signs
// the agent and gh in and clones the repositories: what its jobs need.
func startSetUp(r runAs, root string, env Env) {
	if r.account == "" {
		fmt.Fprintf(env.Stdout, "\nJobs run as you: %s\n"+
			"Set up is what you already have: `slipdock-runner doctor` checks it.\n", executor.Limits[executor.Me])
		return
	}
	fmt.Fprintf(env.Stdout, "\nJobs run as %s: %s\n\n"+
		"Set it up now: a shell as %s opens. Sign in to the agent (`claude`) and to GitHub (`gh auth login`),\n"+
		"clone your repositories under %s, then type `exit`. (Later: `sudo -u %s -i`.)\n\n", r.account, executor.Limits[executor.User], r.account, root, r.account)
	// Interactive, not Run: the shell is the person's to type into.
	if err := env.Interactive("sudo", "-u", r.account, "-i"); err != nil {
		fmt.Fprintf(env.Stdout, "The shell as %s ended: %v. Open it again with `sudo -u %s -i`.\n", r.account, err, r.account)
	}
}

// readLine reads one line a byte at a time, so the next question finds
// the rest of what was typed.
func readLine(r io.Reader) string {
	var b strings.Builder
	buf := make([]byte, 1)
	for {
		n, err := r.Read(buf)
		if n == 1 {
			if buf[0] == '\n' {
				break
			}
			b.WriteByte(buf[0])
		}
		if err != nil {
			break
		}
	}
	return strings.TrimRight(b.String(), "\r")
}
