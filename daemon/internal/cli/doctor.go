package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/enrol"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/service"
)

// A check's outcome.
const (
	ok   = "ok"
	warn = "warn"
	fail = "FAIL"
)

type check struct {
	status, what, detail string
}

// cmdDoctor checks this machine is ready to run jobs, and says how to fix
// what isn't. It fails (exit 1) on any FAIL; a warn is only advice.
func cmdDoctor(args []string, env Env) error {
	fs, home := newFlags("doctor", env)
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	checks := doctorChecks(d, env)
	failed := 0
	for _, c := range checks {
		fmt.Fprintf(env.Stdout, "%-4s  %s", c.status, c.what)
		if c.detail != "" {
			fmt.Fprintf(env.Stdout, ": %s", c.detail)
		}
		fmt.Fprintln(env.Stdout)
		if c.status == fail {
			failed++
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d check(s) failed", failed)
	}
	fmt.Fprintln(env.Stdout, "\nThis machine is ready.")
	return nil
}

func doctorChecks(d string, env Env) []check {
	var out []check
	add := func(status, what, detail string) { out = append(out, check{status, what, detail}) }

	st, key, err := machine.Load(d)
	if err != nil {
		add(fail, "enrolled", err.Error())
		return out
	}
	add(ok, "enrolled", fmt.Sprintf("%s (machine #%d) on %s", st.Name, st.MachineID, st.Server))

	// Unix modes, on the filesystem this is really running on.
	if runtime.GOOS != "windows" {
		add(modeCheck("machine key is readable only by you", filepath.Join(d, machine.KeyFile), 0o600))
		add(modeCheck("the daemon's directory is yours alone", d, 0o700))
	}

	c, err := machine.LoadCeiling(d)
	if err != nil {
		add(fail, "ceiling", err.Error()+" (run init --replace to write one, or fix the file)")
	} else {
		add(ok, "ceiling", fmt.Sprintf("%s; %s; up to %s; %d minutes",
			strings.Join(c.Roots, ", "), strings.Join(c.Agents, ", "), c.MaxPermissionMode, c.MaxTimeoutMinutes))
		for _, r := range c.Roots {
			if fi, err := os.Stat(r); err != nil || !fi.IsDir() {
				add(warn, "working-directory root "+r, "doesn't exist yet: no runner can work there until it does")
			}
		}
		for _, a := range c.Agents {
			out = append(out, agentCheck(a, env))
		}
	}

	client := enrol.NewClient(st.Server, "slipdock-runner/"+Version)
	if env.HTTP != nil {
		client.HTTP = env.HTTP
	}
	ctx, cancel := env.Context()
	defer cancel()
	switch m, err := client.Me(ctx, key); {
	case err == nil && m.State == "revoked":
		add(fail, "the server knows this machine", "it was revoked: run init --replace to enrol it again")
	case err == nil:
		add(ok, "the server knows this machine", fmt.Sprintf("%s, serving %s", m.Name, boardList(m.Boards)))
	case enrol.IsUnauthorized(err):
		add(fail, "the server knows this machine", "it refuses the machine key (revoked?): run init --replace")
	default:
		add(fail, "the server knows this machine", err.Error())
	}

	if _, err := env.LookPath("git"); err != nil {
		add(fail, "git", "not on the PATH: jobs clone and commit with it")
	} else {
		add(ok, "git", "")
	}
	if _, err := env.LookPath("gh"); err != nil {
		add(warn, "gh", "not on the PATH: boards that ship by pull request need it")
	} else if out, err := env.Output("gh", "auth", "status"); err != nil {
		add(warn, "gh", "not logged in (gh auth login): "+firstLine(out))
	} else {
		add(ok, "gh", "logged in")
	}

	add(serviceCheck(d, env))
	add(updateCheck(d))
	return out
}

func modeCheck(what, path string, want os.FileMode) (string, string, string) {
	fi, err := os.Stat(path)
	if err != nil {
		return fail, what, err.Error()
	}
	if got := fi.Mode().Perm(); got&^want != 0 {
		return fail, what, fmt.Sprintf("%s is mode %o: chmod %o %s", path, got, want, path)
	}
	return ok, what, ""
}

// agentCheck finds a built-in agent on the PATH and asks its version. A
// custom command is defined in the machine's local file, which the daemon
// checks when a runner uses it.
func agentCheck(agent string, env Env) check {
	if agent != "claude" && agent != "codex" {
		return check{ok, "agent " + agent, "a custom command: checked against the local file when a runner uses it"}
	}
	if _, err := env.LookPath(agent); err != nil {
		return check{fail, "agent " + agent, "not on the PATH of the account jobs run as"}
	}
	out, err := env.Output(agent, "--version")
	if err != nil {
		return check{fail, "agent " + agent, "`" + agent + " --version` failed: " + firstLine(out)}
	}
	return check{ok, "agent " + agent, firstLine(out)}
}

func serviceCheck(d string, env Env) (string, string, string) {
	spec, err := serviceSpec(d, env)
	if err != nil {
		return warn, "service", err.Error()
	}
	plan, err := service.Build(spec)
	if err != nil {
		return warn, "service", err.Error()
	}
	if _, err := os.Stat(plan.Path); errors.Is(err, os.ErrNotExist) {
		return warn, "service", "not installed: slipdock-runner service install"
	}
	return ok, "service", plan.Path
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}

func boardList(ids []int64) string {
	if len(ids) == 0 {
		return "no boards"
	}
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = fmt.Sprintf("#%d", id)
	}
	return "boards " + strings.Join(parts, ", ")
}
