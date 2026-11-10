package cli

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonlog"
	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/update"
)

// The fixture is a machine's directory as a running daemon leaves it
// (#2652): five runners, one idle, one working, one paused, one whose new
// config the ceiling refused (it keeps v1) and one refused that never ran.
var (
	fixtureNow   = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	fixtureStart = time.Date(2026, 11, 10, 8, 0, 0, 0, time.UTC)
)

func fixtureClock(t *testing.T) {
	old := now
	now = func() time.Time { return fixtureNow }
	t.Cleanup(func() { now = old })
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fixtureRunner(id, version int, name, dir, mode, executor string, paused bool, hooks string) string {
	return `{"id":` + itoa(id) + `,"name":"` + name + `","board_id":3,"pool":"default","config_version":` + itoa(version) +
		`,"paused":` + map[bool]string{true: "true", false: "false"}[paused] +
		`,"config":{"agent":"claude","directory":` + jsonString(dir) + `,"permission_mode":"` + mode +
		`","timeout_minutes":30,"executor":"` + executor + `","worktree":"auto","instructions":"Be brief.\nAnd careful."` + hooks + `}}`
}

// hookPath and accountHome are absolute on every OS (a Windows path
// starts with its drive).
func hookPath(w *world) string    { return filepath.Join(w.home, "hooks", "setup.sh") }
func accountHome(w *world) string { return filepath.Join(w.home, "slipdock-home") }

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

// fixture writes the machine's files into w.dir, and makes the daemon's
// pid alive or not.
func fixture(t *testing.T, w *world, alive bool) {
	t.Helper()
	fixtureClock(t)
	d := w.dir
	root := filepath.Join(w.home, "dev")
	if err := machine.Save(d, machine.State{Server: "https://slipdock.example.com", MachineID: 7, Name: "box", Boards: []int64{3}}, "sdm_key"); err != nil {
		t.Fatal(err)
	}
	if err := machine.SaveCeiling(d, machine.Ceiling{Roots: []string{root}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 120, Boards: []int64{3}, Executors: []string{"me", "user"}}); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(d, machine.LocalFile), `{"hooks":{"setup":{"path":`+jsonString(hookPath(w))+`,"args":["--fast"]}},
		"user":{"name":"slipdock","home":`+jsonString(accountHome(w))+`},
		"runners":{"idle-one":{"env":{"MIX_TEST_PARTITION":"_idle","A_FLAG":"1"}},"gone":{"env":{"MIX_TEST_PARTITION":"_gone"}}}}`)
	writeFile(t, filepath.Join(d, "config-cache.json"), `{"version":12,"runners":[`+
		fixtureRunner(21, 3, "idle-one", filepath.Join(root, "app"), "acceptEdits", "me", false, `,"before_hook":"setup"`)+`,`+
		fixtureRunner(22, 1, "busy-one", filepath.Join(root, "api"), "default", "user", false, `,"after_hook":"notify"`)+`,`+
		fixtureRunner(23, 2, "paused-one", filepath.Join(root, "web"), "plan", "me", true, "")+`,`+
		fixtureRunner(24, 1, "narrowed", filepath.Join(root, "ops"), "acceptEdits", "me", false, "")+`],
		"reported":{"21":{"version":3,"outcome":"accepted"},"22":{"version":1,"outcome":"accepted"},"23":{"version":2,"outcome":"accepted"},
		"24":{"version":2,"outcome":"rejected","reason":"permission mode \"bypassPermissions\" is above acceptEdits"},
		"25":{"version":1,"outcome":"rejected","reason":"directory \"/srv\" is not inside `+strings.Trim(jsonString(root), `"`)+`"}}}`)
	writeFile(t, filepath.Join(d, "changes.log"), strings.Join([]string{
		"2026-11-09T10:00:00Z runner narrowed (#24) v1 added and accepted: permission_mode \"\" → \"acceptEdits\"",
		"2026-11-10T07:00:00Z runner narrowed (#24) v2 rejected, it keeps v1: permission mode \"bypassPermissions\" is above acceptEdits (permission_mode \"acceptEdits\" → \"bypassPermissions\")",
		"2026-11-10T07:01:00Z runner wide (#25) v1 rejected, it doesn't run: directory \"/srv\" is not inside " + root + " (directory \"\" → \"/srv\")",
		"2026-11-10T07:02:00Z runner paused-one (#23) paused",
	}, "\n")+"\n")
	jobs := filepath.Join(d, "jobs")
	done := fixtureStart.Add(time.Hour)
	daemonstate.SaveJob(jobs, 21, daemonstate.Job{ID: 801, CardID: 40, Kind: "claude", Started: fixtureStart, Finished: &done, Status: "succeeded"})
	writeFile(t, filepath.Join(jobs, "21", "job.log"), "starting\nall done: pushed abc123\n\n")
	daemonstate.SaveJob(jobs, 22, daemonstate.Job{ID: 802, CardID: 42, Kind: "claude", Started: fixtureNow.Add(-10 * time.Minute)})
	writeFile(t, filepath.Join(jobs, "22", "job.log"), "cloning\nrunning the tests\n")
	contact := fixtureNow.Add(-2 * time.Minute)
	daemonstate.Save(d, daemonstate.Daemon{PID: 4242, Version: "v1.4.0", Started: fixtureStart, LastContact: &contact, Online: true})
	update.Save(d, update.Settings{Last: &update.Check{At: fixtureStart, Current: "v1.4.0", Latest: "v1.4.0", Outcome: update.Current}})
	writeFile(t, filepath.Join(d, daemonlog.File), strings.Join([]string{
		"2026-11-10T08:00:00Z INFO  slipdock-runner v1.4.0 starting as box (machine #7)",
		"2026-11-10T08:00:01Z DEBUG config version 12: nothing newer",
		"2026-11-10T09:00:00Z WARN  can't reach the server, trying again: timeout",
		"2026-11-10T11:30:00Z ERROR REFUSED an update from https://example.com: bad signature",
		"  (nothing was installed)",
		"2026-11-10T11:50:00Z INFO  enrolled as box, serving boards #3",
	}, "\n")+"\n")
	w.env.Alive = func(pid int) bool { return alive && pid == 4242 }
}

func TestStatusShowsEachRunnersState(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	code := w.main("status")
	out := w.out.String()
	for _, want := range []string{
		"Machine:   box (#7)",
		"Server:    https://slipdock.example.com",
		"Daemon:    running since 2026-11-10T08:00:00Z (pid 4242), version v1.4.0",
		"Contact:   online, the server last answered 2026-11-10T11:58:00Z",
		"Config:    version 12",
		"Updates:   last check current at 2026-11-10T08:00:00Z, latest v1.4.0",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	lines := map[string]string{}
	for _, l := range strings.Split(out, "\n") {
		if name, _, ok := strings.Cut(l, " (#"); ok {
			lines[name] = l
		}
	}
	for name, wants := range map[string][]string{
		"idle-one":   {"#3", "default", "me", "acceptEdits", "idle", "all done: pushed abc123"},
		"busy-one":   {"user", "default", "working on card #42 since 2026-11-10T11:50:00Z (job #802, claude)", "running the tests"},
		"paused-one": {"plan", "paused"},
		"narrowed":   {"refused v2, keeping v1"},
		"wide":       {"refused v1, not running"},
	} {
		for _, want := range wants {
			if !strings.Contains(lines[name], want) {
				t.Errorf("runner %s: missing %q in %q", name, want, lines[name])
			}
		}
	}
	if strings.Contains(lines["paused-one"], "idle") {
		t.Errorf("a paused runner isn't idle: %q", lines["paused-one"])
	}
	// A refused runner fails it, and says why.
	if code != 1 || !strings.Contains(w.errOut.String(), `runner narrowed (#24) v2 is refused: permission mode "bypassPermissions" is above acceptEdits`) ||
		!strings.Contains(w.errOut.String(), "runner wide (#25) v1 is refused") || strings.Contains(w.errOut.String(), "isn't running") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}

	// With nothing refused and the daemon running, it passes.
	writeFile(t, filepath.Join(w.dir, "config-cache.json"), `{"version":12,"runners":[`+
		fixtureRunner(21, 3, "idle-one", filepath.Join(w.home, "dev", "app"), "acceptEdits", "me", false, "")+`],"reported":{}}`)
	if code := w.main("status"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
}

func TestStatusWhenTheDaemonIsntRunning(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, false)
	code := w.main("status")
	out := w.out.String()
	if code != 1 || !strings.Contains(w.errOut.String(), "the daemon isn't running") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(out, "Daemon:    not running (pid 4242, started 2026-11-10T08:00:00Z, has gone without saying it stopped)") {
		t.Errorf("gone:\n%s", out)
	}
	// The job it held isn't being worked on now.
	if !strings.Contains(out, "was on card #42 (job #802) when the daemon stopped") || strings.Contains(out, "working on") {
		t.Errorf("interrupted:\n%s", out)
	}

	// Stopped, and saying so; offline before that.
	stopped := fixtureNow.Add(-time.Minute)
	contact := fixtureNow.Add(-time.Hour)
	daemonstate.Save(w.dir, daemonstate.Daemon{PID: 4242, Version: Version, Started: fixtureStart, Stopped: &stopped,
		LastContact: &contact, LastError: "dial tcp: timeout"})
	w.env.Alive = func(int) bool { return true }
	if code := w.main("status"); code != 1 || !strings.Contains(w.out.String(), "Daemon:    not running (stopped 2026-11-10T11:59:00Z)") ||
		!strings.Contains(w.out.String(), "Contact:   offline: last answered 2026-11-10T11:00:00Z, then dial tcp: timeout") {
		t.Fatalf("stopped: %d\n%s", code, w.out)
	}

	// A daemon that never wrote its state, and a machine with no runners.
	os.Remove(filepath.Join(w.dir, daemonstate.File))
	os.Remove(filepath.Join(w.dir, "config-cache.json"))
	os.Remove(filepath.Join(w.dir, update.File))
	if code := w.main("status"); code != 1 || !strings.Contains(w.out.String(), "not running (no daemon-state.json") ||
		!strings.Contains(w.out.String(), "No runners") || !strings.Contains(w.out.String(), "Updates:   not checked yet") {
		t.Fatalf("no state: %d\n%s", code, w.out)
	}

	empty := newWorld(t)
	if code := empty.main("status"); code != 1 || !strings.Contains(empty.errOut.String(), "not enrolled") {
		t.Fatalf("unenrolled: %d %s", code, empty.errOut)
	}
}

func TestStatusJSON(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	if code := w.main("status", "--json"); code != 1 {
		t.Fatalf("exit %d: refused runners fail --json too", code)
	}
	var s struct {
		Running       bool  `json:"running"`
		ConfigVersion int64 `json:"config_version"`
		Machine       struct {
			Name string `json:"name"`
		} `json:"machine"`
		Runners []struct {
			ID      int64  `json:"id"`
			Name    string `json:"name"`
			State   string `json:"state"`
			Last    string `json:"last_log_line"`
			Refused *struct {
				Version, Keeping int64
				Reason           string
			} `json:"refused"`
			Job *struct {
				CardID int64 `json:"card_id"`
			} `json:"job"`
		} `json:"runners"`
		Update *update.Check `json:"update"`
	}
	if err := json.Unmarshal(w.out.Bytes(), &s); err != nil {
		t.Fatalf("%v:\n%s", err, w.out)
	}
	if !s.Running || s.ConfigVersion != 12 || s.Machine.Name != "box" || s.Update == nil || len(s.Runners) != 5 {
		t.Fatalf("%+v", s)
	}
	states := map[string]string{}
	for _, r := range s.Runners {
		states[r.Name] = r.State
	}
	want := map[string]string{"idle-one": "idle", "busy-one": "working", "paused-one": "paused", "narrowed": "refused", "wide": "refused"}
	for name, state := range want {
		if states[name] != state {
			t.Errorf("%s: state %q, want %q", name, states[name], state)
		}
	}
	if r := s.Runners[3]; r.Refused == nil || r.Refused.Version != 2 || r.Refused.Keeping != 1 {
		t.Errorf("narrowed: %+v", r.Refused)
	}
	if r := s.Runners[1]; r.Job == nil || r.Job.CardID != 42 || r.Last != "running the tests" {
		t.Errorf("busy-one: %+v", r)
	}
}

func TestLogFiltersTheDaemonsLog(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	lines := func(args ...string) []string {
		t.Helper()
		if code := w.main(append([]string{"log"}, args...)...); code != 0 {
			t.Fatalf("log %v: exit %d: %s", args, code, w.errOut)
		}
		return strings.Split(strings.TrimRight(w.out.String(), "\n"), "\n")
	}
	if got := lines(); len(got) != 6 || !strings.Contains(got[0], "starting as box") {
		t.Fatalf("everything: %q", got)
	}
	// --level keeps that level and above; a continued line goes with its own.
	got := lines("--level", "warn")
	if len(got) != 3 || !strings.Contains(got[0], "WARN") || !strings.Contains(got[1], "ERROR") || got[2] != "  (nothing was installed)" {
		t.Fatalf("--level warn: %q", got)
	}
	if got := lines("--level", "error"); len(got) != 2 || !strings.Contains(got[0], "REFUSED") {
		t.Fatalf("--level error: %q", got)
	}
	if got := lines("--level", "info"); len(got) != 5 || strings.Contains(strings.Join(got, "\n"), "DEBUG") {
		t.Fatalf("--level info: %q", got)
	}
	// --since: the last 45 minutes (the clock is 12:00).
	if got := lines("--since", "45m"); len(got) != 3 || !strings.Contains(got[0], "11:30:00Z ERROR") {
		t.Fatalf("--since 45m: %q", got)
	}
	if got := lines("--since", "1d", "--level", "error"); len(got) != 2 {
		t.Fatalf("--since 1d --level error: %q", got)
	}
	// -n: the last N lines kept.
	if got := lines("-n", "1"); len(got) != 1 || !strings.Contains(got[0], "enrolled as box") {
		t.Fatalf("-n 1: %q", got)
	}
	// The rotated file comes first.
	writeFile(t, filepath.Join(w.dir, daemonlog.Rotated), "2026-11-09T08:00:00Z INFO  yesterday\n")
	if got := lines("-n", "0"); len(got) != 7 || !strings.Contains(got[0], "yesterday") {
		t.Fatalf("rotated: %q", got)
	}
	if got := lines("--since", "2h"); strings.Contains(strings.Join(got, "\n"), "yesterday") {
		t.Fatalf("--since leaves the rotated file's older lines out: %q", got)
	}
}

func TestLogReadsAJobsLog(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	for _, args := range [][]string{{"--runner", "busy-one"}, {"--runner", "22"}, {"--job", "802"}} {
		if code := w.main(append([]string{"log"}, args...)...); code != 0 || w.out.String() != "cloning\nrunning the tests\n" {
			t.Fatalf("log %v: %d %q %s", args, code, w.out, w.errOut)
		}
	}
	if code := w.main("log", "--runner", "idle-one", "-n", "1"); code != 0 || w.out.String() != "all done: pushed abc123\n" {
		t.Fatalf("-n 1 skips the blank line: %d %q", code, w.out)
	}
	for args, want := range map[string]string{
		"--runner nobody":     `no runner here is called "nobody"`,
		"--runner paused-one": "has no job log yet",
		"--job 999":           "job #999 isn't the job any runner here holds or held last",
	} {
		if code := w.main(append([]string{"log"}, strings.Fields(args)...)...); code != 1 || !strings.Contains(w.errOut.String(), want) {
			t.Errorf("log %s: %d %s", args, code, w.errOut)
		}
	}
	// Mistakes in the command line.
	for _, args := range []string{"--runner busy-one --job 802", "--runner busy-one --level warn", "--job 802 --since 1h",
		"--level loud", "--since soon", "--since -1h", "-n -1"} {
		if code := w.main(append([]string{"log"}, strings.Fields(args)...)...); code != 2 {
			t.Errorf("log %s: exit %d, want 2: %s", args, code, w.errOut)
		}
	}
}

// --follow prints what is written after, in the daemon's log (filtered,
// and from the start after a rotation) and in a job's.
func TestLogFollows(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	path := filepath.Join(w.dir, daemonlog.File)
	appendTo := func(p, s string) {
		f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o600)
		f.WriteString(s)
		f.Close()
	}
	steps := []func(){
		func() { appendTo(path, "2026-11-10T12:00:01Z INFO  quiet\n2026-11-10T12:00:02Z WARN  first new\n") },
		func() { appendTo(path, "2026-11-10T12:00:03Z ERROR half") }, // not a whole line yet
		func() { appendTo(path, " a line\n  more of it\n") },
		func() { os.Rename(path, path+".1"); writeFile(t, path, "2026-11-10T12:00:04Z WARN  after rotating\n") },
	}
	w.env.Sleep = func(ctx context.Context, d time.Duration) error {
		if len(steps) == 0 {
			return context.Canceled
		}
		steps[0]()
		steps = steps[1:]
		return nil
	}
	if code := w.main("log", "--follow", "--level", "warn", "-n", "1"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	want := "2026-11-10T11:30:00Z ERROR REFUSED an update from https://example.com: bad signature\n" +
		"  (nothing was installed)\n" +
		"2026-11-10T12:00:02Z WARN  first new\n" +
		"2026-11-10T12:00:03Z ERROR half a line\n" +
		"  more of it\n" +
		"2026-11-10T12:00:04Z WARN  after rotating\n"
	// -n 1 counts lines, so the last kept is the continued one; then the new.
	if got := w.out.String(); got != strings.SplitN(want, "\n", 2)[1] {
		t.Fatalf("got:\n%s\nwant:\n%s", got, strings.SplitN(want, "\n", 2)[1])
	}

	jobLog := filepath.Join(w.dir, "jobs", "22", "job.log")
	steps = []func(){
		func() { appendTo(jobLog, "tests passed\n") },
		func() { writeFile(t, jobLog, "the next job\n") }, // a new job starts its log again
	}
	if code := w.main("log", "-f", "--runner", "busy-one", "-n", "1"); code != 0 ||
		w.out.String() != "running the tests\ntests passed\nthe next job\n" {
		t.Fatalf("job log: %d %q", code, w.out)
	}
}

func TestLogBeforeTheDaemonHasRun(t *testing.T) {
	w := newWorld(t)
	if code := w.main("log"); code != 0 || !strings.Contains(w.errOut.String(), "no log yet") {
		t.Fatalf("%d %s", code, w.errOut)
	}
}

// squash makes each run of spaces one, so a test doesn't hang on the
// columns' widths.
func squash(s string) string { return regexp.MustCompile(` {2,}`).ReplaceAllString(s, " ") }

func TestConfigPrintsTheMachinesSettings(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	if code := w.main("config"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := squash(w.out.String())
	for _, want := range []string{
		"Ceiling (" + filepath.Join(w.dir, machine.CeilingFile) + ")",
		"max permission mode:  acceptEdits",
		"executors:            me, user",
		"Local (" + filepath.Join(w.dir, machine.LocalFile) + ")",
		jsonString(hookPath(w)),
		"Runners (config version 12)",
		"idle-one (#21) v3 accepted\n",
		"paused-one (#23) v2 accepted, paused",
		"before_hook:      setup",
		"instructions:     Be brief. …",
		"narrowed (#24) v1 accepted",
		`REFUSED v2, it keeps v1: permission mode "bypassPermissions" is above acceptEdits`,
		`changes.log 2026-11-10T07:00:00Z: runner narrowed (#24) v2 rejected, it keeps v1`,
		"wide (#25)\n REFUSED v1, it doesn't run: directory \"/srv\"",
	} {
		if !strings.Contains(out, squash(want)) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "effective:") {
		t.Errorf("names resolved without --effective")
	}
}

func TestConfigEffectiveResolvesNames(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	if code := w.main("config", "--effective"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := squash(w.out.String())
	root := filepath.Join(w.home, "dev")
	for _, want := range []string{
		"agent claude:         /usr/bin/claude",
		"before_hook setup:    " + hookPath(w) + " --fast",
		"env:                  A_FLAG=1 MIX_TEST_PARTITION=_idle",
		"runs as:              me: builder, as it is",
		"root:                 " + filepath.Join(root, "app") + " is inside " + root,
		// busy-one runs as the dedicated account, whose PATH the daemon can't see.
		"agent claude:        claude (looked up on slipdock's PATH when a job runs)",
		"after_hook notify:   NOT DEFINED in local.json's hooks: every job fails before it starts",
		"runs as:             user: the dedicated account slipdock (" + accountHome(w) + ")",
	} {
		if !strings.Contains(out, squash(want)) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}

	if strings.Count(out, "env:") != 1 || strings.Contains(strings.SplitN(out, "Runners (", 2)[1], "_gone") {
		t.Errorf("only the runner the local file names shows an env row:\n%s", out)
	}

	// No local.json: claude found on the PATH, or not; the hook undefined.
	os.Remove(filepath.Join(w.dir, machine.LocalFile))
	w.paths["claude"] = false
	if code := w.main("config", "--effective"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out = squash(w.out.String())
	for _, want := range []string{
		"none: claude and codex are found on the PATH",
		"agent claude:         claude (NOT on the PATH: no job can run)",
		"before_hook setup:    NOT DEFINED in local.json's hooks",
		"runs as:             user: no dedicated account is set up",
	} {
		if !strings.Contains(out, squash(want)) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}

	// A runner whose directory a narrowed ceiling no longer covers.
	elsewhere := filepath.Join(w.home, "elsewhere")
	if err := machine.SaveCeiling(w.dir, machine.Ceiling{Roots: []string{elsewhere}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 120, Boards: []int64{3}}); err != nil {
		t.Fatal(err)
	}
	w.main("config", "--effective")
	if !strings.Contains(w.out.String(), filepath.Join(root, "app")+" is OUTSIDE every root ("+elsewhere+")") {
		t.Errorf("outside:\n%s", w.out)
	}
	// No ceiling at all: said, not a failure.
	os.Remove(filepath.Join(w.dir, machine.CeilingFile))
	if code := w.main("config", "--effective"); code != 0 || !strings.Contains(w.out.String(), "can't be read") ||
		!strings.Contains(squash(w.out.String()), "root: unknown: the ceiling can't be read") {
		t.Fatalf("no ceiling: %d\n%s", code, w.out)
	}
}

func TestConfigJSONDumpsTheThreeFiles(t *testing.T) {
	w := newWorld(t)
	fixture(t, w, true)
	os.Remove(filepath.Join(w.dir, machine.LocalFile))
	if code := w.main("config", "--json"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	var got struct {
		Ceiling     *machine.Ceiling `json:"ceiling"`
		Local       *machine.Local   `json:"local"`
		ConfigCache *struct {
			Version int64 `json:"version"`
		} `json:"config_cache"`
	}
	if err := json.Unmarshal(w.out.Bytes(), &got); err != nil {
		t.Fatalf("%v:\n%s", err, w.out)
	}
	if got.Ceiling == nil || got.Ceiling.MaxTimeoutMinutes != 120 || got.Local != nil || got.ConfigCache == nil || got.ConfigCache.Version != 12 {
		t.Fatalf("%+v\n%s", got, w.out)
	}
	writeFile(t, filepath.Join(w.dir, "config-cache.json"), "{broken")
	if code := w.main("config", "--json"); code != 1 || !strings.Contains(w.errOut.String(), "is not valid JSON") {
		t.Fatalf("broken: %d %s", code, w.errOut)
	}
	if code := w.main("config", "--json", "--effective"); code != 2 {
		t.Fatalf("--json --effective: %d", code)
	}
	// A broken local.json is said, as run would refuse it.
	writeFile(t, filepath.Join(w.dir, machine.LocalFile), `{"command":"x"}`)
	if code := w.main("config"); code != 1 || !strings.Contains(w.errOut.String(), "the local file") {
		t.Fatalf("a broken local file: %d %s", code, w.errOut)
	}
}

// run writes its levelled log to daemon.log in the daemon's directory as
// well as to stderr or --log, at --log-level, else local.json's log_level,
// else info; and keeps daemon-state.json.
func TestRunLogsAtTheLevelAsked(t *testing.T) {
	w, _ := enrolled(t)
	w.stopAfterSleep = 2
	if code := w.main("run"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	daemonLog, _ := os.ReadFile(filepath.Join(w.dir, daemonlog.File))
	for _, out := range []string{string(daemonLog), w.errOut.String()} {
		if !strings.Contains(out, " INFO  enrolled as box, serving boards #3") || strings.Contains(out, " DEBUG ") {
			t.Fatalf("at info:\n%s", out)
		}
	}
	st, err := daemonstate.Load(w.dir)
	if err != nil || st == nil || st.PID != os.Getpid() || st.Stopped == nil || st.Online || st.LastContact == nil {
		t.Fatalf("daemon-state.json: %+v %v", st, err)
	}

	// --log-level warn: nothing at info, in either.
	os.Remove(filepath.Join(w.dir, daemonlog.File))
	w.sleeps = 0
	logFile := filepath.Join(t.TempDir(), "run.log")
	if code := w.main("run", "--log-level", "warn", "--log", logFile); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	daemonLog, _ = os.ReadFile(filepath.Join(w.dir, daemonlog.File))
	logged, _ := os.ReadFile(logFile)
	if strings.Contains(string(daemonLog), "INFO") || strings.Contains(string(logged), "INFO") || w.errOut.Len() != 0 {
		t.Fatalf("at warn:\n%s\n--\n%s\n--\n%s", daemonLog, logged, w.errOut)
	}

	// local.json's log_level, and --log-level over it.
	writeFile(t, filepath.Join(w.dir, machine.LocalFile), `{"log_level":"debug"}`)
	w.sleeps = 0
	if code := w.main("run"); code != 0 || !strings.Contains(w.errOut.String(), " DEBUG ") {
		t.Fatalf("local debug: %d\n%s", code, w.errOut)
	}
	w.sleeps = 0
	if code := w.main("run", "--log-level", "error"); code != 0 || strings.Contains(w.errOut.String(), "INFO") || strings.Contains(w.errOut.String(), "DEBUG") {
		t.Fatalf("--log-level over local.json: %d\n%s", code, w.errOut)
	}

	// --log naming daemon.log itself writes each line once.
	os.Remove(filepath.Join(w.dir, machine.LocalFile))
	os.Remove(filepath.Join(w.dir, daemonlog.File))
	w.sleeps = 0
	if code := w.main("run", "--log", filepath.Join(w.dir, daemonlog.File)); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	daemonLog, _ = os.ReadFile(filepath.Join(w.dir, daemonlog.File))
	if strings.Count(string(daemonLog), "starting as box") != 1 {
		t.Fatalf("once:\n%s", daemonLog)
	}

	if code := w.main("run", "--log-level", "loud"); code != 2 || !strings.Contains(w.errOut.String(), `"loud"`) {
		t.Fatalf("a level that isn't one: %d %s", code, w.errOut)
	}
}

// A server that can't be reached is a WARN, and daemon-state.json says so.
func TestRunWarnsWhenTheServerCantBeReached(t *testing.T) {
	w, _ := enrolled(t)
	st, key, _ := machine.Load(w.dir)
	st.Server = "http://127.0.0.1:1"
	machine.Save(w.dir, st, key)
	w.stopAfterSleep = 1
	if code := w.main("run", "--log-level", "warn"); code != 0 || !strings.Contains(w.errOut.String(), " WARN  can't reach the server") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	d, _ := daemonstate.Load(w.dir)
	if d == nil || d.Online || d.LastContact != nil || d.LastError == "" {
		t.Fatalf("daemon-state.json: %+v", d)
	}
}

func TestTheUsageNamesTheMachinesOwnCommands(t *testing.T) {
	w := newWorld(t)
	w.main("help")
	for _, want := range []string{"slipdock-runner status [--json]", "slipdock-runner log [--level L] [--since DUR] [-n N] [--follow] [--runner NAME | --job ID]",
		"slipdock-runner config [--effective | --json]", "run [--log FILE] [--log-level debug|info|warn|error]", "daemon.log"} {
		if !strings.Contains(w.out.String(), want) {
			t.Errorf("usage is missing %q:\n%s", want, w.out)
		}
	}
}
