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
//   - container: in a short-lived Docker or Podman container (#2577), from
//     the image the runner names, only if it matches the machine's
//     allow-list (container_images in its ceiling). Linux and macOS.
//
// Windows offers me only. An executor that can't run a job says why
// (Ready), and the job fails before anything starts: a job is never run
// under a weaker executor in its place.
package executor

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
		"state (~/.claude for claude); in a worktree, a job whose card has paths writes " +
		"only those in it. The runner's hooks and the daemon's own git " +
		"for it are confined to its repository and worktrees. Jobs can still read " +
		"your files, and reach the network unless a trust tier holds them to an allowlist. Linux (Landlock ABI 3: kernel 6.2 or " +
		"later) and macOS (sandbox-exec) only.",
	Container: "Jobs run in a short-lived Docker or Podman container, from an image on " +
		"this machine's allow-list. They see only what is mounted: their directory " +
		"and repository (read-write; in a worktree whose card has paths, only those " +
		"paths and what a commit needs), the agent's and the CLI's logins (read-only), and " +
		"an empty directory of the job's own for the agent's transcript, which the daemon " +
		"reads only as regular files beneath it; the home is otherwise empty. The network is off when the runner asks, " +
		"and held to an allowlist when a trust tier says (Linux). They " +
		"still reach the network when it is on, carry the logins mounted in, and are " +
		"only as safe as the image and the runtime (a user in the docker group is root " +
		"on the machine). Linux and macOS only.",
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
	// Paths, under confined and container (#3521): when set, the only
	// paths in Dir and Writable the job may write (real paths beneath
	// them: its card's paths in its worktree and the git internals a
	// commit writes), in place of all of Dir and Writable, which stay
	// readable. Empty: all of Dir and Writable. Never a hook's.
	Paths []string
	// Scratch, under confined: the job's own temporary directory, its
	// TMPDIR.
	Scratch string
	// Transcripts, under container: the agent's own fresh directory for
	// its transcripts (#2625), mounted read-write at the home's
	// .claude/projects. Only the agent's process gets one, never the
	// hooks' or the daemon's own git.
	Transcripts string
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
	// Repo, under confined and container: the runner's directory. The
	// daemon's own git and the hooks may write it, its repository and its
	// worktrees.
	Repo string

	// Under container (#2577). Image is the runner's (the server's data);
	// Images the machine's allow-list (its ceiling's container_images).
	Image      string
	Images     []string
	NetworkOff bool
	// Runtime is docker, podman or a path (default: docker, else podman);
	// Pull is never (the default), missing or always.
	Runtime string
	Pull    string
	// Login is mounted read-only at the same paths, each inside Home (nil:
	// DefaultLogin for Agent). PassEnv are the daemon's variables a job
	// gets (nil: DefaultPassEnv for Agent).
	Login   []string
	PassEnv []string
	Agent   string
	// CLI is the machine's slipdock CLI, mounted read-only over the image's.
	CLI string
	// Protected are never mounted, nor anything holding them: the
	// daemon's own directory.
	Protected []string
	// UID and GID are who the container runs as (default: the daemon's).
	UID, GID int

	// Egress, under confined and container, is the job's network
	// allowlist (#3517): its proxy, the only way out.
	Egress *Egress
}

// Egress is a job's proxy, which a confined or container job reaches
// and nothing else: confined, its port on 127.0.0.1 (and the machine's
// own ports the allowlist names); in a container with no network, its
// unix socket, mounted in, which the daemon's own binary carries the
// same port to.
type Egress struct {
	Port   int
	Socket string
	// Direct are ports of the machine itself a confined job may reach
	// outside the proxy (allow_hosts' localhost:port).
	Direct []int
	// Tripwire, under container, is a directory of the job's fake
	// credentials (#3524), which the proxy watches for: its .aws and
	// .config/gh are mounted read-only at the same places in the job's
	// home, unless a login mounted there is the machine's own.
	Tripwire string
}

// TripwireDirs are what of Egress.Tripwire is mounted, by path under the
// home.
var TripwireDirs = []string{".aws", filepath.Join(".config", "gh")}

// addr is the proxy's address, as the job's processes reach it.
func (e *Egress) addr() string { return fmt.Sprintf("127.0.0.1:%d", e.Port) }

// ports are the loopback ports the job may connect to: the proxy's, then
// the direct ones.
func (e *Egress) ports() []int { return append([]int{e.Port}, e.Direct...) }

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
		if goos != "linux" && goos != "darwin" {
			return fmt.Errorf("container is Linux and macOS only, not %s", goos)
		}
		return nil
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
	case Container:
		// The allow-list is checked here, and again before each process.
		if err := ImageAllowed(s.Image, s.Images); err != nil {
			return nil, err
		}
		if s.UID == 0 && s.GID == 0 {
			s.UID, s.GID = os.Getuid(), os.Getgid()
		}
		return newContainer(s), nil
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
