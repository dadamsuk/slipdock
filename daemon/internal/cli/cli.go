// Package cli is slipdock-runner's commands: init, setup, show, status,
// log, config, doctor, service, run, update and version. Everything outside the process (the terminal, the
// environment, the network, the clock, other programs) comes in through
// Env, so each command can be tested on its own.
package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// Version is set at build time (-ldflags "-X …/cli.Version=v1.2.3").
var Version = "dev"

// DefaultServer is offered when init asks for the server.
const DefaultServer = "https://app.slipdock.us"

// Env is the world a command runs in.
type Env struct {
	Stdin          io.Reader
	Stdout, Stderr io.Writer
	Getenv         func(string) string
	Hostname       func() (string, error)
	UserHome       func() (string, error)
	Executable     func() (string, error)
	GOOS, GOARCH   string
	// OSName describes the OS for the approval page: GOOS, or "linux (WSL)".
	OSName      func() string
	OpenBrowser func(url string) error
	LookPath    func(string) (string, error)
	// Run runs a program, its output to the terminal.
	Run func(name string, args ...string) error
	// Interactive runs a program attached to the terminal: its stdin as
	// well as its output, for a program a person talks to (claude).
	Interactive func(name string, args ...string) error
	// Output runs a program and returns what it printed.
	Output func(name string, args ...string) (string, error)
	Sleep  func(context.Context, time.Duration) error
	HTTP   *http.Client
	// Context is cancelled when the process is asked to stop.
	Context func() (context.Context, context.CancelFunc)
	// Account names the OS account the daemon runs as.
	Account func() string
	// HomeOpen says whether a home is open to other accounts.
	HomeOpen func(home string) bool
	// Alive says whether a process is running (status: the daemon's pid).
	Alive func(pid int) bool
}

// DefaultEnv is the real world.
func DefaultEnv() Env {
	return Env{
		Stdin:      os.Stdin,
		Stdout:     os.Stdout,
		Stderr:     os.Stderr,
		Getenv:     os.Getenv,
		Hostname:   os.Hostname,
		UserHome:   os.UserHomeDir,
		Executable: executable,
		GOOS:       runtime.GOOS,
		GOARCH:     runtime.GOARCH,
		OSName:     osName,
		OpenBrowser: func(url string) error {
			return openBrowser(runtime.GOOS, url, func(name string, args ...string) error {
				return exec.Command(name, args...).Start()
			})
		},
		LookPath: exec.LookPath,
		Run: func(name string, args ...string) error {
			cmd := exec.Command(name, args...)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			return cmd.Run()
		},
		Interactive: func(name string, args ...string) error {
			cmd := exec.Command(name, args...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			return cmd.Run()
		},
		Output: func(name string, args ...string) (string, error) {
			out, err := exec.Command(name, args...).CombinedOutput()
			return string(out), err
		},
		Sleep: nil,
		HTTP:  &http.Client{Timeout: 30 * time.Second},
		Context: func() (context.Context, context.CancelFunc) {
			return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		},
		Account: account,
		Alive:   processAlive,
		HomeOpen: func(home string) bool {
			return executor.HomeOpen(runtime.GOOS, home)
		},
	}
}

func executable() (string, error) {
	p, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(p)
}

func osName() string {
	if runtime.GOOS == "linux" {
		if v, err := os.ReadFile("/proc/version"); err == nil && strings.Contains(strings.ToLower(string(v)), "microsoft") {
			return "linux (WSL)"
		}
	}
	return runtime.GOOS
}

func account() string {
	for _, k := range []string{"USER", "USERNAME", "LOGNAME"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return "this account"
}

// openBrowser opens url with the platform's opener.
func openBrowser(goos, url string, start func(string, ...string) error) error {
	switch goos {
	case "darwin":
		return start("open", url)
	case "windows":
		return start("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		return start("xdg-open", url)
	}
}

const usage = `slipdock-runner: the Slipdock runner daemon, one per machine.

Usage:
  slipdock-runner init [--server URL] [--allow-http] [--key KEY] [--replace] [--user NAME | --as-me] [--no-setup]
                                          enrol this machine, and choose who jobs run as
  slipdock-runner setup [--print]         set this machine up with Claude, from the server's prompt
  slipdock-runner show                    the trust contract, with this machine's limits
  slipdock-runner status [--json]         what the daemon and each runner are doing now
  slipdock-runner log [--level L] [--since DUR] [-n N] [--follow] [--runner NAME | --job ID]
                                          the daemon's log, or a runner's job log
  slipdock-runner config [--effective | --json]
                                          the ceiling, local.json and each runner's accepted settings
  slipdock-runner doctor                  check this machine is ready to run jobs
  slipdock-runner service install|uninstall|print
  slipdock-runner run [--log FILE] [--log-level debug|info|warn|error]
                                          run this machine's runners (what the service runs)
  slipdock-runner update [--check] [--mode auto|manual] [--source URL]
                                          install a newer signed release, or set how updates go
  slipdock-runner version

Every command takes --home DIR, the daemon's directory (default: %s,
or $SLIPDOCK_RUNNER_HOME). status, log and config read only that directory:
they work with the server down. run also writes its log, levelled, to
daemon.log there.
`

// errUsage marks a mistake in the command line: exit status 2.
var errUsage = errors.New("usage")

// Main runs one command and answers with the process's exit status.
func Main(args []string, env Env) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprintf(env.Stdout, usage, defaultDirText(env))
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	cmd, rest := args[0], args[1:]
	var err error
	switch cmd {
	case "init":
		err = cmdInit(rest, env)
	case "setup":
		err = cmdSetup(rest, env)
	case "show":
		err = cmdShow(rest, env)
	case "status":
		err = cmdStatus(rest, env)
	case "log":
		err = cmdLog(rest, env)
	case "config":
		err = cmdConfig(rest, env)
	case "doctor":
		err = cmdDoctor(rest, env)
	case "service":
		err = cmdService(rest, env)
	case "run":
		err = cmdRun(rest, env)
	case "update":
		err = cmdUpdate(rest, env)
	case "confine":
		// How the daemon starts a confined job on Linux; not for people.
		return executor.ConfineMain(rest, env.Stderr)
	case "version", "--version":
		fmt.Fprintf(env.Stdout, "slipdock-runner %s (%s/%s)\n", Version, env.GOOS, env.GOARCH)
	default:
		fmt.Fprintf(env.Stderr, "slipdock-runner: unknown command %q\n\n", cmd)
		fmt.Fprintf(env.Stderr, usage, defaultDirText(env))
		return 2
	}
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errUsage), errors.Is(err, flag.ErrHelp):
		return 2
	default:
		fmt.Fprintf(env.Stderr, "slipdock-runner %s: %v\n", cmd, err)
		return 1
	}
}

func defaultDirText(env Env) string {
	dir, err := machine.Dir(func(string) string { return "" })
	if err != nil {
		return "your config directory"
	}
	return dir
}

// newFlags is a flag set that reports to stderr and takes --home.
func newFlags(name string, env Env) (*flag.FlagSet, *string) {
	fs := flag.NewFlagSet("slipdock-runner "+name, flag.ContinueOnError)
	fs.SetOutput(env.Stderr)
	home := fs.String("home", "", "the daemon's directory")
	return fs, home
}

func parse(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return err
		}
		return errUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(fs.Output(), "%s: unexpected %q\n", fs.Name(), fs.Arg(0))
		return errUsage
	}
	return nil
}

// dir is the daemon's directory: --home, else machine.Dir.
func dir(home string, env Env) (string, error) {
	if home != "" {
		return filepath.Abs(home)
	}
	return machine.Dir(env.Getenv)
}

// list is a repeatable string flag.
type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }
