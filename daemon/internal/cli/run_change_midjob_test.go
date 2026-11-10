package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonlog"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// What a change to a runner's settings does to the job it is running
// (#2665): the daemon takes the change at once (it is reported accepted),
// but the job runs on to its own end with the settings it started with,
// and is reported as it ended, not stopped or cut short. Only the runner's
// next claim, once that job has finished, is made with the new settings.
// The old worker's "took no more jobs" line is logged after the job, not
// during it.
func TestASettingsChangeMidJobLetsTheJobFinish(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake agent is a shell script")
	}
	srv := &configServer{}
	w, start := liveWorld(t, srv)
	repo := filepath.Join(w.home, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	// The agent writes the arguments it was given (the settings it runs
	// with), says it started, and runs until it is released.
	scratch := t.TempDir()
	argsFile, started, release := filepath.Join(scratch, "args"), filepath.Join(scratch, "started"), filepath.Join(scratch, "release")
	script := `echo "$*" >> "` + argsFile + `"; touch "` + started + `"; while [ ! -e "` + release + `" ]; do sleep 0.05; done`
	local, _ := json.Marshal(machine.Local{
		Agents:         map[string]machine.Command{"claude": {Path: "/bin/sh", Args: []string{"-c", script, "agent"}}},
		NoSkillsUpdate: true,
		NoCLIUpdate:    true,
	})
	if err := os.WriteFile(filepath.Join(w.dir, machine.LocalFile), local, 0o600); err != nil {
		t.Fatal(err)
	}
	srv.jobs = map[string][]int64{"21": {501, 502}}
	srv.set(runnerJSON(21, 1, repo, "default", false))
	stop := start()

	waitUntil(t, "job 501 to start", func() bool { _, err := os.Stat(started); return err == nil })
	held := srv.claimsOf("21")

	// The runner's settings change while job 501 runs.
	srv.set(runnerJSON(21, 2, repo, "acceptEdits", false))
	waitUntil(t, "the change to be taken", func() bool {
		return strings.Contains(srv.reported(), "21 v2 accepted") &&
			strings.Contains(daemonLog(w), "runner r21 (#21) changed: it starts again with its new config once the job it holds has finished")
	})
	time.Sleep(300 * time.Millisecond) // the job runs on a while after the change
	srv.mu.Lock()
	finishes, claims := strings.Join(srv.finishes, "; "), srv.claims["21"]
	srv.mu.Unlock()
	if finishes != "" || claims != held {
		t.Fatalf("the change cut job 501 short: finishes %q, claims %d → %d", finishes, held, claims)
	}
	if log := daemonLog(w); strings.Contains(log, "took no more jobs") || strings.Contains(log, "told to stop") {
		t.Fatalf("the runner ended while its job ran:\n%s", log)
	}

	// The job ends by itself: reported as it ended, and the next claim,
	// with the new settings, comes only after it.
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "both jobs to finish", func() bool {
		srv.mu.Lock()
		defer srv.mu.Unlock()
		return len(srv.finishes) == 2
	})
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	srv.mu.Lock()
	got := strings.Join(srv.finishes, "\n")
	srv.mu.Unlock()
	if !strings.HasPrefix(got, "501 exit=0 status= after claim "+strconv.Itoa(held)+"\n502 exit=0 status= ") {
		t.Fatalf("finishes:\n%s", got)
	}
	args, _ := os.ReadFile(argsFile)
	lines := strings.Split(strings.TrimSpace(string(args)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], "--permission-mode default") || !strings.Contains(lines[1], "--permission-mode acceptEdits") {
		t.Fatalf("the held job should run with the old settings and the next with the new:\n%s", args)
	}
	log := w.errOut.String()
	ended := strings.Index(log, "runner r21 (#21) took no more jobs and ended")
	if ended < 0 || ended < strings.Index(log, "job #501: exit 0") {
		t.Fatalf("the old worker's end isn't logged after its job:\n%s", log)
	}
	if strings.Contains(log, "stopped: this runner was told to stop") {
		t.Fatalf("an ordinary end between jobs is logged as a stop:\n%s", log)
	}
}

// daemonLog is the running daemon's own log file, which can be read while
// it writes (its stderr, w.errOut, can't).
func daemonLog(w *world) string {
	b, _ := os.ReadFile(filepath.Join(w.dir, daemonlog.File))
	return string(b)
}
