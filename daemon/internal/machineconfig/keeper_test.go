package machineconfig

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
)

// server records reports, failing them while down.
type server struct {
	reports []string
	down    bool
}

func (s *server) Report(_ context.Context, id, version int64, outcome, reason string) error {
	if s.down {
		return errors.New("connection refused")
	}
	line := outcome
	if reason != "" {
		line += ": " + reason
	}
	s.reports = append(s.reports, fmt.Sprintf("%d v%d %s", id, version, line))
	return nil
}

func itoa(n int64) string { return fmt.Sprint(n) }

type rig struct {
	t    *testing.T
	dir  string
	root string
	srv  *server
	k    *Keeper
	logs []string
}

func newRig(t *testing.T) *rig {
	base := t.TempDir()
	r := &rig{t: t, dir: filepath.Join(base, "machine"), root: filepath.Join(base, "src"), srv: &server{}}
	if err := os.MkdirAll(r.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	r.k = r.keeper(r.ceiling())
	return r
}

func (r *rig) ceiling() machine.Ceiling {
	return machine.Ceiling{Roots: []string{r.root}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 60, Boards: []int64{3}}
}

func (r *rig) keeper(c machine.Ceiling) *Keeper {
	return &Keeper{Dir: r.dir, Ceiling: c, Server: r.srv,
		Logf: func(f string, a ...any) { r.logs = append(r.logs, fmt.Sprintf(f, a...)) },
		Now:  func() time.Time { return time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC) }}
}

func (r *rig) listed(id, version int64, mode string) runner.Listed {
	return runner.Listed{Runner: runner.Runner{ID: id, Name: "builder", BoardID: 3, Pool: "default", ConfigVersion: version,
		Config: runner.Config{Agent: "claude", Directory: filepath.Join(r.root, "repo"), PermissionMode: mode,
			TimeoutMinutes: 30, Executor: "me"}}}
}

func (r *rig) changes() string {
	data, _ := os.ReadFile(filepath.Join(r.dir, ChangeLog))
	return string(data)
}

func modes(rs []runner.Runner) []string {
	var out []string
	for _, x := range rs {
		out = append(out, itoa(x.ID)+":"+x.Config.PermissionMode)
	}
	return out
}

func TestInsideIsAcceptedOutsideRejectedAndThePreviousKept(t *testing.T) {
	r := newRig(t)
	running := r.k.Apply(&runner.Listing{Version: 1, Runners: []runner.Listed{r.listed(21, 1, "default")}})
	r.k.Flush(context.Background())
	if got := modes(running); len(got) != 1 || got[0] != "21:default" {
		t.Fatalf("running %v", got)
	}
	if len(r.srv.reports) != 1 || r.srv.reports[0] != "21 v1 accepted" {
		t.Fatalf("reports %v", r.srv.reports)
	}

	// Above the ceiling's mode: rejected with the reason, and v1 runs on.
	running = r.k.Apply(&runner.Listing{Version: 2, Runners: []runner.Listed{r.listed(21, 2, "bypassPermissions")}})
	r.k.Flush(context.Background())
	if got := modes(running); len(got) != 1 || got[0] != "21:default" {
		t.Fatalf("a rejected config replaced the accepted one: %v", got)
	}
	if len(r.srv.reports) != 2 || !strings.HasPrefix(r.srv.reports[1], `21 v2 rejected: permission mode "bypassPermissions" is above acceptEdits`) {
		t.Fatalf("reports %v", r.srv.reports)
	}
	log := r.changes()
	for _, want := range []string{
		"2026-11-09T12:00:00Z runner builder (#21) v1 added and accepted: ",
		`permission_mode "" → "default"`,
		`runner builder (#21) v2 rejected, it keeps v1: permission mode "bypassPermissions" is above acceptEdits (permission_mode "default" → "bypassPermissions")`,
	} {
		if !strings.Contains(log, want) {
			t.Errorf("the change log doesn't say %q:\n%s", want, log)
		}
	}
	if !strings.Contains(strings.Join(r.logs, "\n"), "runner builder (#21) v2 is outside this machine's ceiling, so it keeps v1") {
		t.Errorf("daemon log:\n%s", strings.Join(r.logs, "\n"))
	}

	// The same listing again: nothing new is reported or logged.
	before := r.changes()
	r.k.Apply(&runner.Listing{Version: 2, Runners: []runner.Listed{r.listed(21, 2, "bypassPermissions")}})
	r.k.Flush(context.Background())
	if len(r.srv.reports) != 2 || r.changes() != before {
		t.Fatalf("a repeat was reported or logged again: %v\n%s", r.srv.reports, r.changes())
	}

	// Back inside: accepted, the change logged as a diff.
	running = r.k.Apply(&runner.Listing{Version: 3, Runners: []runner.Listed{r.listed(21, 3, "acceptEdits")}})
	r.k.Flush(context.Background())
	if got := modes(running); got[0] != "21:acceptEdits" || r.srv.reports[2] != "21 v3 accepted" {
		t.Fatalf("running %v, reports %v", got, r.srv.reports)
	}
	if !strings.Contains(r.changes(), `runner builder (#21) v3 changed and accepted: permission_mode "default" → "acceptEdits"`) {
		t.Fatalf("change log:\n%s", r.changes())
	}
}

func TestANewRunnerOutsideTheCeilingDoesntRun(t *testing.T) {
	r := newRig(t)
	wide := r.listed(22, 1, "default")
	wide.Config.Directory = "/etc"
	wide.BoardID = 9
	running := r.k.Apply(&runner.Listing{Version: 1, Runners: []runner.Listed{wide}})
	r.k.Flush(context.Background())
	if len(running) != 0 {
		t.Fatalf("running %v", running)
	}
	if len(r.srv.reports) != 1 || !strings.Contains(r.srv.reports[0], `22 v1 rejected: directory "/etc" is not inside`) ||
		!strings.Contains(r.srv.reports[0], "board #9 is not one this machine serves") {
		t.Fatalf("reports %v", r.srv.reports)
	}
	if !strings.Contains(r.changes(), "runner builder (#22) v1 rejected, it doesn't run: ") {
		t.Fatalf("change log:\n%s", r.changes())
	}
}

func TestPauseResumeAndRemove(t *testing.T) {
	r := newRig(t)
	a, b := r.listed(21, 1, "default"), r.listed(22, 1, "default")
	r.k.Apply(&runner.Listing{Version: 1, Runners: []runner.Listed{a, b}})

	a.Paused, a.ConfigVersion = true, 2
	if got := modes(r.k.Apply(&runner.Listing{Version: 2, Runners: []runner.Listed{a, b}})); len(got) != 1 || got[0] != "22:default" {
		t.Fatalf("a paused runner runs: %v", got)
	}
	if !strings.Contains(r.changes(), "runner builder (#21) v2 changed and accepted: paused false → true") {
		t.Fatalf("change log:\n%s", r.changes())
	}

	// A pause is taken even when the rest of the change is rejected: it
	// only narrows.
	a.Paused, a.ConfigVersion = false, 3
	r.k.Apply(&runner.Listing{Version: 3, Runners: []runner.Listed{a, b}})
	b.Paused, b.ConfigVersion, b.Config.PermissionMode = true, 2, "bypassPermissions"
	got := modes(r.k.Apply(&runner.Listing{Version: 4, Runners: []runner.Listed{a, b}}))
	if len(got) != 1 || got[0] != "21:default" {
		t.Fatalf("running %v: 21 resumed, 22 paused", got)
	}
	if !strings.Contains(r.changes(), "runner builder (#22) paused") {
		t.Fatalf("change log:\n%s", r.changes())
	}

	// Removed from the server: it doesn't run, and that is logged.
	if got := r.k.Apply(&runner.Listing{Version: 5, Runners: []runner.Listed{b}}); len(got) != 0 {
		t.Fatalf("running %v", modes(got))
	}
	if !strings.Contains(r.changes(), "runner builder (#21) removed: it finishes the job it holds, then stops") {
		t.Fatalf("change log:\n%s", r.changes())
	}
	if r.k.Version() != 5 {
		t.Fatalf("version %d", r.k.Version())
	}
}

func TestTheCacheStartsADaemonOffline(t *testing.T) {
	r := newRig(t)
	if had, err := r.k.Load(); had || err != nil {
		t.Fatalf("no cache yet: %v %v", had, err)
	}
	a, b := r.listed(21, 4, "default"), r.listed(22, 2, "acceptEdits")
	b.Config.Directory = filepath.Join(r.root, "other")
	r.k.Apply(&runner.Listing{Version: 7, Runners: []runner.Listed{a, b}})
	r.k.Flush(context.Background())

	// A new daemon, offline: it runs what was accepted, at its version, and
	// doesn't report again what was reported.
	k := r.keeper(r.ceiling())
	if had, err := k.Load(); !had || err != nil {
		t.Fatalf("load: %v %v", had, err)
	}
	if got := modes(k.Running()); k.Version() != 7 || len(got) != 2 || got[0] != "21:default" || got[1] != "22:acceptEdits" {
		t.Fatalf("version %d, running %v", k.Version(), got)
	}
	k.Apply(&runner.Listing{Version: 7, Runners: []runner.Listed{a, b}})
	k.Flush(context.Background())
	if len(r.srv.reports) != 2 {
		t.Fatalf("reported again after a restart: %v", r.srv.reports)
	}

	// The ceiling narrowed at the machine since: a cached runner now
	// outside it doesn't run.
	narrow := r.ceiling()
	narrow.MaxPermissionMode = "default"
	k = r.keeper(narrow)
	k.Load()
	if got := modes(k.Running()); len(got) != 1 || got[0] != "21:default" {
		t.Fatalf("running %v", got)
	}

	if runtime.GOOS != "windows" {
		for _, f := range []string{CacheFile, ChangeLog} {
			fi, err := os.Stat(filepath.Join(r.dir, f))
			if err != nil || fi.Mode().Perm() != 0o600 {
				t.Errorf("%s: %v %v, want owner-only", f, fi.Mode(), err)
			}
		}
	}
	leftovers, _ := filepath.Glob(filepath.Join(r.dir, CacheFile+".*"))
	if len(leftovers) != 0 {
		t.Fatalf("temporary files left: %v", leftovers)
	}

	// A broken cache is an error, not a start from nothing silently.
	os.WriteFile(filepath.Join(r.dir, CacheFile), []byte("{"), 0o600)
	if _, err := r.keeper(r.ceiling()).Load(); err == nil || !strings.Contains(err.Error(), CacheFile) {
		t.Fatalf("err = %v", err)
	}
}

func TestAReportThatFailsIsSentLater(t *testing.T) {
	r := newRig(t)
	r.srv.down = true
	r.k.Apply(&runner.Listing{Version: 1, Runners: []runner.Listed{r.listed(21, 1, "default")}})
	r.k.Flush(context.Background())
	if r.k.Pending() != 1 || len(r.srv.reports) != 0 {
		t.Fatalf("pending %d, reports %v", r.k.Pending(), r.srv.reports)
	}
	if !strings.Contains(strings.Join(r.logs, "\n"), "can't report runner #21's config v1 (accepted) yet") {
		t.Fatalf("log:\n%s", strings.Join(r.logs, "\n"))
	}
	r.srv.down = false
	r.k.Flush(context.Background())
	if r.k.Pending() != 0 || len(r.srv.reports) != 1 || r.srv.reports[0] != "21 v1 accepted" {
		t.Fatalf("pending %d, reports %v", r.k.Pending(), r.srv.reports)
	}
	// A runner removed while its report waits: the report is dropped.
	r.srv.down = true
	r.k.Apply(&runner.Listing{Version: 2, Runners: []runner.Listed{r.listed(22, 1, "default")}})
	r.k.Apply(&runner.Listing{Version: 3})
	if r.k.Pending() != 0 {
		t.Fatalf("pending %d", r.k.Pending())
	}
}

func TestDiffNamesEachFieldThatChanged(t *testing.T) {
	a := runner.Listed{Runner: runner.Runner{Name: "x", Config: runner.Config{Model: "opus", TimeoutMinutes: 5}}}
	b := a
	if diff(a, b) != "no field changed" {
		t.Fatal(diff(a, b))
	}
	b.Pool, b.Config.Model, b.Config.TimeoutMinutes = "verify", "", 6
	if got := diff(a, b); got != `pool "" → "verify"; timeout_minutes 5 → 6; model "opus" → ""` {
		t.Fatal(got)
	}
}
