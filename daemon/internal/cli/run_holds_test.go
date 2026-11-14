package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// The daemon's runners share one set of holds (#2920): one runner's agent
// hitting its usage limit stops every runner of that agent taking a job,
// not one at a time. Runner 21's job hits the limit; runner 22, given a job
// once the hold is on, never runs the agent for it (it claims nothing, or
// gives the job back unrun).
func TestTheDaemonsRunnersShareTheHold(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake agent is a shell script")
	}
	srv := &configServer{}
	w, start := liveWorld(t, srv)
	runs := filepath.Join(t.TempDir(), "runs")
	script := `echo run >> "` + runs + `"; echo "You've hit your weekly limit · resets 11:59pm"; exit 1`
	local, _ := json.Marshal(machine.Local{
		Agents:         map[string]machine.Command{"claude": {Path: "/bin/sh", Args: []string{"-c", script, "agent"}}},
		NoSkillsUpdate: true,
		NoCLIUpdate:    true,
	})
	if err := os.WriteFile(filepath.Join(w.dir, machine.LocalFile), local, 0o600); err != nil {
		t.Fatal(err)
	}
	var dirs []string
	for _, name := range []string{"a", "b"} {
		d := filepath.Join(w.home, name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		dirs = append(dirs, d)
	}
	srv.mu.Lock()
	srv.jobs = map[string][]int64{"21": {501}}
	srv.mu.Unlock()
	srv.set(runnerJSON(21, 1, dirs[0], "default", false), runnerJSON(22, 1, dirs[1], "default", false))
	stop := start()

	finished := func() string {
		srv.mu.Lock()
		defer srv.mu.Unlock()
		return strings.Join(srv.finishes, "\n")
	}
	waitUntil(t, "job 501 to go back", func() bool { return strings.Contains(finished(), "501 exit=1 status=requeue") })
	srv.mu.Lock()
	srv.jobs["22"] = []int64{601}
	srv.mu.Unlock()
	time.Sleep(500 * time.Millisecond) // runner 22 would claim and run 601 in this time, unheld
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if got, _ := os.ReadFile(runs); strings.Count(string(got), "run") != 1 {
		t.Fatalf("the agent ran %d times, want once: runner 22 isn't held by 21's limit\nfinishes:\n%s", strings.Count(string(got), "run"), finished())
	}
	for _, line := range strings.Split(finished(), "\n") {
		if strings.HasPrefix(line, "601 ") && !strings.Contains(line, "status=requeue") {
			t.Fatalf("job 601 ran: %s", line)
		}
	}
}
