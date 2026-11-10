package cli

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
	"github.com/dadamsuk/slipdock/daemon/internal/update"
)

// Runner states, as status reports them.
const (
	stateIdle    = "idle"
	stateWorking = "working"
	statePaused  = "paused"
	stateRefused = "refused"
	// stateCut: the runner held a job when the daemon stopped.
	stateCut = "interrupted"
)

// machineStatus is what status reports, and --json prints.
type machineStatus struct {
	Version       string              `json:"version"`
	Machine       statusMachine       `json:"machine"`
	Running       bool                `json:"running"`
	Daemon        *daemonstate.Daemon `json:"daemon"`
	ConfigVersion int64               `json:"config_version"`
	Runners       []runnerStatus      `json:"runners"`
	Update        *update.Check       `json:"update"`
}

type statusMachine struct {
	Name   string `json:"name"`
	ID     int64  `json:"id"`
	Server string `json:"server"`
}

type runnerStatus struct {
	ID             int64            `json:"id"`
	Name           string           `json:"name"`
	BoardID        int64            `json:"board_id,omitempty"`
	Pool           string           `json:"pool,omitempty"`
	Executor       string           `json:"executor,omitempty"`
	PermissionMode string           `json:"permission_mode,omitempty"`
	ConfigVersion  int64            `json:"config_version,omitempty"`
	State          string           `json:"state"`
	Paused         bool             `json:"paused"`
	Refused        *refusal         `json:"refused,omitempty"`
	Job            *daemonstate.Job `json:"job,omitempty"`
	LastLogLine    string           `json:"last_log_line,omitempty"`
}

// refusal is a runner's config the ceiling refused: the version refused,
// and the one it keeps (0: none, so it doesn't run).
type refusal struct {
	Version int64  `json:"version"`
	Keeping int64  `json:"keeping"`
	Reason  string `json:"reason"`
}

// cmdStatus says what the machine is doing, from its own files (#2652):
// the daemon, each runner and the last update check. It fails when the
// daemon isn't running or a runner's config is refused.
func cmdStatus(args []string, env Env) error {
	fs, home := newFlags("status", env)
	asJSON := fs.Bool("json", false, "print it as JSON")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	s, err := readStatus(d, env)
	if err != nil {
		return err
	}
	if *asJSON {
		out, err := json.MarshalIndent(s, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintf(env.Stdout, "%s\n", out)
	} else {
		printStatus(s, env)
	}
	return s.problem()
}

// readStatus reads the machine's files into a machineStatus.
func readStatus(d string, env Env) (machineStatus, error) {
	st, _, err := machine.Load(d)
	if err != nil {
		return machineStatus{}, err
	}
	s := machineStatus{Version: Version, Machine: statusMachine{Name: st.Name, ID: st.MachineID, Server: st.Server}}
	if s.Daemon, err = daemonstate.Load(d); err != nil {
		return s, err
	}
	alive := env.Alive
	if alive == nil {
		alive = processAlive
	}
	s.Running = s.Daemon != nil && s.Daemon.Stopped == nil && alive(s.Daemon.PID)
	cache, err := machineconfig.ReadCache(d)
	if err != nil {
		return s, err
	}
	if cache != nil {
		s.ConfigVersion = cache.Version
		s.Runners = runnerStatuses(d, cache, s.Running)
	}
	u, err := update.Load(d)
	if err != nil {
		return s, err
	}
	s.Update = u.Last
	return s, nil
}

// runnerStatuses is one line per runner the cache knows: each accepted
// one, and each whose last report was a refusal, by id.
func runnerStatuses(d string, c *machineconfig.Cache, running bool) []runnerStatus {
	byID := map[int64]*runnerStatus{}
	for _, l := range c.Runners {
		byID[l.ID] = &runnerStatus{
			ID: l.ID, Name: l.Name, BoardID: l.BoardID, Pool: l.Pool, Executor: l.Config.Executor,
			PermissionMode: l.Config.PermissionMode, ConfigVersion: l.ConfigVersion, Paused: l.Paused,
		}
	}
	for id, rep := range c.Reported {
		if rep.Outcome != "rejected" {
			continue
		}
		r, ok := byID[id]
		if !ok {
			r = &runnerStatus{ID: id, Name: refusedName(d, id)}
			byID[id] = r
		}
		r.Refused = &refusal{Version: rep.Version, Keeping: r.ConfigVersion, Reason: rep.Reason}
	}
	jobsDir := filepath.Join(d, "jobs")
	var out []runnerStatus
	for _, r := range byID {
		r.Job, _ = daemonstate.LoadJob(jobsDir, r.ID)
		r.LastLogLine = lastLine(filepath.Join(jobsDir, fmt.Sprint(r.ID), "job.log"))
		r.State = r.state(running)
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (r runnerStatus) state(running bool) string {
	switch {
	case r.Job != nil && r.Job.Finished == nil && running:
		return stateWorking
	case r.Job != nil && r.Job.Finished == nil:
		return stateCut
	case r.Refused != nil:
		return stateRefused
	case r.Paused:
		return statePaused
	}
	return stateIdle
}

// describe is the state in words.
func (r runnerStatus) describe() string {
	var parts []string
	switch r.State {
	case stateWorking:
		parts = append(parts, fmt.Sprintf("working on card #%d since %s (job #%d, %s)", r.Job.CardID, stamp(r.Job.Started), r.Job.ID, r.Job.Kind))
	case stateCut:
		parts = append(parts, fmt.Sprintf("was on card #%d (job #%d) when the daemon stopped", r.Job.CardID, r.Job.ID))
	case stateIdle:
		parts = append(parts, "idle")
	}
	if r.Paused {
		parts = append(parts, "paused")
	}
	if f := r.Refused; f != nil {
		kept := "not running"
		if f.Keeping > 0 {
			kept = fmt.Sprintf("keeping v%d", f.Keeping)
		}
		parts = append(parts, fmt.Sprintf("refused v%d, %s", f.Version, kept))
	}
	return strings.Join(parts, "; ")
}

// problem is why status exits non-zero: the daemon not running, or a
// runner refused.
func (s machineStatus) problem() error {
	var problems []string
	if !s.Running {
		problems = append(problems, "the daemon isn't running")
	}
	for _, r := range s.Runners {
		if r.Refused != nil {
			problems = append(problems, fmt.Sprintf("runner %s (#%d) v%d is refused: %s", r.Name, r.ID, r.Refused.Version, r.Refused.Reason))
		}
	}
	if len(problems) == 0 {
		return nil
	}
	return errors.New(strings.Join(problems, "; "))
}

func printStatus(s machineStatus, env Env) {
	out := env.Stdout
	fmt.Fprintf(out, "slipdock-runner %s\n", s.Version)
	fmt.Fprintf(out, "Machine:   %s (#%d)\n", s.Machine.Name, s.Machine.ID)
	fmt.Fprintf(out, "Server:    %s\n", s.Machine.Server)
	fmt.Fprintf(out, "Daemon:    %s\n", daemonLine(s))
	fmt.Fprintf(out, "Contact:   %s\n", contactLine(s.Daemon))
	fmt.Fprintf(out, "Config:    version %d\n", s.ConfigVersion)
	fmt.Fprintln(out)
	if len(s.Runners) == 0 {
		fmt.Fprintln(out, "No runners: the daemon hasn't taken in a config with any yet.")
	} else {
		tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
		fmt.Fprintln(tw, "RUNNER\tBOARD\tPOOL\tEXECUTOR\tMODE\tSTATE\tLAST LOG LINE")
		for _, r := range s.Runners {
			fmt.Fprintf(tw, "%s (#%d)\t%s\t%s\t%s\t%s\t%s\t%s\n", r.Name, r.ID, orDash(boardText(r.BoardID)), orDash(r.Pool),
				orDash(r.Executor), orDash(r.PermissionMode), r.describe(), orDash(clip(r.LastLogLine, 60)))
		}
		tw.Flush()
	}
	fmt.Fprintln(out)
	if u := s.Update; u != nil {
		line := fmt.Sprintf("%s at %s", u.Outcome, stamp(u.At))
		if u.Latest != "" {
			line += ", latest " + u.Latest
		}
		if u.Reason != "" {
			line += ": " + u.Reason
		}
		fmt.Fprintf(out, "Updates:   last check %s\n", line)
	} else {
		fmt.Fprintln(out, "Updates:   not checked yet")
	}
}

func daemonLine(s machineStatus) string {
	d := s.Daemon
	switch {
	case d == nil:
		return "not running (no " + daemonstate.File + ": it hasn't run since it was installed or updated to a version that writes one)"
	case s.Running:
		line := fmt.Sprintf("running since %s (pid %d)", stamp(d.Started), d.PID)
		if d.Version != s.Version {
			line += ", version " + d.Version
		}
		return line
	case d.Stopped != nil:
		return fmt.Sprintf("not running (stopped %s)", stamp(*d.Stopped))
	}
	return fmt.Sprintf("not running (pid %d, started %s, has gone without saying it stopped)", d.PID, stamp(d.Started))
}

func contactLine(d *daemonstate.Daemon) string {
	switch {
	case d == nil:
		return "unknown"
	case d.Online && d.LastContact != nil:
		return "online, the server last answered " + stamp(*d.LastContact)
	case d.LastContact != nil && d.LastError != "":
		return fmt.Sprintf("offline: last answered %s, then %s", stamp(*d.LastContact), d.LastError)
	case d.LastContact != nil:
		return "the server last answered " + stamp(*d.LastContact)
	case d.LastError != "":
		return "the server hasn't answered: " + d.LastError
	}
	return "the server hasn't answered yet"
}

// refusedName is a runner's name for one the machine never accepted:
// from the last line about it in changes.log.
func refusedName(d string, id int64) string {
	line := lastChange(d, id)
	if name, _, ok := strings.Cut(strings.TrimPrefix(line.text, "runner "), fmt.Sprintf(" (#%d)", id)); ok && line.text != "" {
		return name
	}
	return "?"
}

// change is one line of changes.log.
type change struct {
	at   string
	text string
}

// lastChange is the last line of changes.log about runner id, if any.
func lastChange(d string, id int64) change {
	var last change
	f, err := os.Open(filepath.Join(d, machineconfig.ChangeLog))
	if err != nil {
		return last
	}
	defer f.Close()
	mark := fmt.Sprintf(" (#%d) ", id)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		at, text, _ := strings.Cut(sc.Text(), " ")
		if strings.HasPrefix(text, "runner ") && strings.Contains(text, mark) {
			last = change{at: at, text: text}
		}
	}
	return last
}

// lastLine is a file's last non-empty line, or "".
func lastLine(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	// Read the tail only: a job's log can be long.
	const tail = 16 * 1024
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		f.Seek(st.Size()-tail, 0)
	}
	var last string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		if t := strings.TrimSpace(sc.Text()); t != "" {
			last = t
		}
	}
	return last
}

func stamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func boardText(id int64) string {
	if id == 0 {
		return ""
	}
	return fmt.Sprintf("#%d", id)
}

// clip shortens s to n runes, with an ellipsis.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// listedName is the runner a cache accepted, by id.
func listedName(c *machineconfig.Cache, id int64) (runner.Listed, bool) {
	if c == nil {
		return runner.Listed{}, false
	}
	for _, l := range c.Runners {
		if l.ID == id {
			return l, true
		}
	}
	return runner.Listed{}, false
}
