// Package executor runs a job's processes under the executor its runner
// names (W-2543, W-2544 part 6):
//
//   - me: as the account the daemon runs as, with its environment.
//   - user: as a dedicated account (slipdock by default), through
//     `sudo -n -u <account>`, with a clean environment of its own. A job is
//     refused while the enrolling user's home is open to that account.
//   - confined: as the daemon's account, but unable to write outside its
//     working directory: Landlock on Linux (applied by `slipdock-runner
//     confine` before it runs the program), sandbox-exec on macOS.
//
// container is a name the server knows, but no executor here yet (#2577).
// Windows offers me only. An executor that can't run a job says why
// (Ready), and the job fails before anything starts: a job is never run
// under a weaker executor in its place.
package executor

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// The executors' names, as the server's runner config has them.
const (
	Me        = "me"
	User      = "user"
	Confined  = "confined"
	Container = "container"
)

// Names are every executor a runner may name.
var Names = []string{Me, User, Confined, Container}

// Limits says, for each executor, what it does and doesn't stop: what
// init, the manual and the trust contract tell a person.
var Limits = map[string]string{
	Me: "Jobs run as you, with your files, keys and logins. Nothing stops an agent " +
		"reading or changing what you can.",
	User: "Jobs run as a dedicated account with its own home, logins and clones. " +
		"It can't read your home (a job is refused while your home is open to it), " +
		"but it reads what any account can, can write its own home and /tmp, and " +
		"reaches the network.",
	Confined: "Jobs run as you but can't write outside their working directory, " +
		"their own temporary directory, the terminal devices and the agent's own " +
		"state (~/.claude for claude). The runner's hooks and the daemon's own git " +
		"for it are confined to its repository and worktrees. Jobs can still read " +
		"your files, and reach the network. Linux (Landlock ABI 3: kernel 6.2 or " +
		"later) and macOS (sandbox-exec) only.",
	Container: "Not available on this daemon yet.",
}

// Proc is what one of a job's processes needs.
type Proc struct {
	// Dir is where it runs: the runner's directory, or the job's worktree.
	Dir string
	// Env is the job's own variables (SLIPDOCK_*), on top of the
	// executor's base environment.
	Env []string
	// Writable, under confined: what the job may write besides Dir (the
	// repository, when Dir is a worktree of it).
	Writable []string
	// Scratch, under confined: the job's own temporary directory, its
	// TMPDIR.
	Scratch string
	// noState leaves out the agent's own state (Settings.Writable): the
	// daemon's own work and the hooks aren't the agent.
	noState bool
}

// Executor runs a job's processes.
type Executor interface {
	Name() string
	// Ready says why no job can run under the executor now, or nil.
	Ready() error
	// Command is prog run under the executor, for the agent and the hooks:
	// not started, in a process group of its own.
	Command(p Proc, prog string, args ...string) (*exec.Cmd, error)
	// Exec runs one of the daemon's own commands (git, gh) as the account
	// jobs run as, in dir, and returns what it printed.
	Exec(ctx context.Context, dir, name string, args ...string) (string, error)
	// Stop asks a started command and everything it started to stop, or
	// makes them (force).
	Stop(cmd *exec.Cmd, force bool)
	// Resolve finds a program as the account jobs run as would.
	Resolve(prog string) (string, error)
	// IsDir says whether the account jobs run as sees a directory at path.
	IsDir(path string) bool
	// Files reads the files of the account jobs run as: the agent's
	// transcripts and the installed skills.
	Files() Files
	// Home is the home of the account jobs run as.
	Home() string
}

// Settings are what New needs to know about the machine.
type Settings struct {
	GOOS string
	// Home is the daemon's own account's home.
	Home string
	// Getenv is the daemon's environment; Environ lists it.
	Getenv  func(string) string
	Environ func() []string
	// LookPath finds a program on the daemon's PATH.
	LookPath func(string) (string, error)

	// Account, under user: the dedicated account's name, home and PATH.
	Account     string
	AccountHome string
	AccountPath string

	// Launcher, under confined on Linux: the slipdock-runner binary,
	// whose `confine` command applies Landlock and runs the program.
	Launcher string
	// Writable, under confined: paths every job may write besides its own
	// (the agent's own state). Missing ones are left out.
	Writable []string
	// Repo, under confined: the runner's directory. The daemon's own git
	// and the hooks may write it, its repository and its worktrees.
	Repo string
}

// Hooker is an executor whose hooks run differently from its agent.
type Hooker interface {
	Hook(ctx context.Context, p Proc, prog string, args ...string) (*exec.Cmd, error)
}

// Supported says whether this daemon can run jobs under name on goos at
// all, and why not.
func Supported(name, goos string) error {
	switch name {
	case Me:
		return nil
	case User:
		if goos == "windows" {
			return errors.New("on Windows jobs run as the current account only (executor me)")
		}
		return nil
	case Confined:
		if goos != "linux" && goos != "darwin" {
			return fmt.Errorf("confined is Linux and macOS only, not %s", goos)
		}
		return nil
	case Container:
		return errors.New("container is not available on this daemon yet")
	}
	return fmt.Errorf("%q is not an executor (%s)", name, strings.Join(Names, ", "))
}

// Offered is what init offers on goos: me, then user when the dedicated
// account is set up, then confined where it exists. Windows: me only.
func Offered(goos string, account bool) []string {
	if goos == "windows" {
		return []string{Me}
	}
	out := []string{Me}
	if account {
		out = append(out, User)
	}
	if Supported(Confined, goos) == nil {
		out = append(out, Confined)
	}
	return out
}

// New is the executor name, for this machine.
func New(name string, s Settings) (Executor, error) {
	if err := Supported(name, s.GOOS); err != nil {
		return nil, err
	}
	base := &local{s: s}
	switch name {
	case User:
		if s.Account == "" {
			return nil, errors.New("no dedicated account is set up for the user executor: run `slipdock-runner init --replace` and choose one")
		}
		return newAccount(s), nil
	case Confined:
		return &confined{local: base}, nil
	}
	return base, nil
}

// run is exec with a deadline, for the short checks.
func run(ctx context.Context, cmd *exec.Cmd) (string, error) {
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return string(out), ctx.Err()
	}
	return string(out), err
}

const checkTimeout = 30 * time.Second
