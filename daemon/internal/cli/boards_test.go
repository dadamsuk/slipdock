package cli

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
)

// handRoot is an absolute root on every OS the daemon is tested on.
var handRoot = map[bool]string{true: "C:/src", false: "/src"}[runtime.GOOS == "windows"]

// handCeiling is a ceiling as a person might have written it: no
// executors named, an image allow-list, mode 0640.
var handCeiling = `{
  "roots": ["` + handRoot + `"],
  "agents": ["claude", "codex"],
  "max_permission_mode": "plan",
  "max_timeout_minutes": 30,
  "boards": [3],
  "container_images": ["ghcr.io/example/*"]
}
`

func writeHandCeiling(t *testing.T, w *world) string {
	t.Helper()
	if err := os.MkdirAll(w.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(w.dir, machine.CeilingFile)
	if err := os.WriteFile(path, []byte(handCeiling), 0o640); err != nil {
		t.Fatal(err)
	}
	os.Chmod(path, 0o640)
	return path
}

func TestBoardsListsAddsAndRemovesKeepingTheRest(t *testing.T) {
	w := newWorld(t)
	path := writeHandCeiling(t, w)

	if code := w.main("boards"); code != 0 || !strings.Contains(w.out.String(), "This machine serves boards #3 (its ceiling: "+path+")") {
		t.Fatalf("list: exit %d: %s%s", code, w.out, w.errOut)
	}

	w.out.Reset()
	if code := w.main("boards", "add", "5", "3", "#7", "--home", w.dir); code != 0 {
		t.Fatalf("add: exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"Board #3 is in the ceiling already: nothing to add.",
		"Added boards #5, #7 to the ceiling", "This machine now serves boards #3, #5, #7.",
		"A running daemon picks this up within a minute: no restart needed."} {
		if !strings.Contains(out, want) {
			t.Errorf("add doesn't say %q:\n%s", want, out)
		}
	}
	c, err := machine.LoadCeiling(w.dir)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(c.Boards) != "[3 5 7]" {
		t.Fatalf("boards %v after add, want [3 5 7]", c.Boards)
	}
	if fmt.Sprintf("%v %v %v %v %v", c.Agents, c.Roots, c.MaxPermissionMode, c.MaxTimeoutMinutes, c.ContainerImages) != "[claude codex] ["+handRoot+"] plan 30 [ghcr.io/example/*]" {
		t.Errorf("the other fields changed: %+v", c)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "executors") {
		t.Errorf("the edit wrote executors the file left out:\n%s", data)
	}
	// Windows keeps no Unix mode: a file there reads as 0666.
	if fi, _ := os.Stat(path); runtime.GOOS != "windows" && fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %o after the edit, want the file's own 0640", fi.Mode().Perm())
	}

	w.out.Reset()
	if code := w.main("boards", "remove", "5", "9"); code != 0 {
		t.Fatalf("remove: exit %d: %s", code, w.errOut)
	}
	out = w.out.String()
	for _, want := range []string{"Board #9 isn't in the ceiling: nothing to remove.",
		"Removed board #5 from the ceiling", "This machine now serves boards #3, #7.",
		"the job it holds finishes first"} {
		if !strings.Contains(out, want) {
			t.Errorf("remove doesn't say %q:\n%s", want, out)
		}
	}
	if c, _ := machine.LoadCeiling(w.dir); fmt.Sprint(c.Boards) != "[3 7]" {
		t.Fatalf("boards %v after remove, want [3 7]", c.Boards)
	}

	// Nothing to do: the file isn't written.
	before, _ := os.Stat(path)
	time.Sleep(10 * time.Millisecond)
	w.out.Reset()
	if code := w.main("boards", "add", "7"); code != 0 || !strings.Contains(w.out.String(), "is unchanged") ||
		strings.Contains(w.out.String(), "no restart") {
		t.Fatalf("a no-op add: exit %d: %s", code, w.out)
	}
	if after, _ := os.Stat(path); !after.ModTime().Equal(before.ModTime()) {
		t.Error("a no-op add wrote the file")
	}
}

func TestBoardsRefusesTheLastBoardAndABadID(t *testing.T) {
	w := newWorld(t)
	path := writeHandCeiling(t, w)

	if code := w.main("boards", "remove", "3"); code != 1 ||
		!strings.Contains(w.errOut.String(), "revoke it on the Machines page instead") {
		t.Fatalf("removing the last board: exit %d: %s", code, w.errOut)
	}
	for _, bad := range []string{"x", "0", "1.5", "#"} {
		w.errOut.Reset()
		if code := w.main("boards", "add", bad); code != 2 || !strings.Contains(w.errOut.String(), "is not a board id") {
			t.Errorf("add %q: exit %d: %s", bad, code, w.errOut)
		}
	}
	for _, args := range [][]string{{"boards", "add"}, {"boards", "drop", "5"}} {
		if code := w.main(args...); code != 2 {
			t.Errorf("%v: exit %d, want a usage error", args, code)
		}
	}
	if data, _ := os.ReadFile(path); string(data) != handCeiling {
		t.Fatalf("a refused edit changed the file:\n%s", data)
	}

	empty := newWorld(t)
	if code := empty.main("boards"); code != 1 || !strings.Contains(empty.errOut.String(), "there is no ceiling at") {
		t.Fatalf("no ceiling: exit %d: %s", code, empty.errOut)
	}
}

// boardRunner is runnerJSON's runner on another board.
func boardRunner(id, board int, dir string) string {
	return strings.Replace(runnerJSON(id, 1, dir, "default", false), `"board_id":3`, fmt.Sprintf(`"board_id":%d`, board), 1)
}

// ceilingLive is liveWorld with the server's ceiling endpoint answered by
// a ceilingServer, and the daemon's log readable while it runs.
func ceilingLive(t *testing.T, cfg *configServer) (*world, *ceilingServer, *lockedBuffer, func() func() int) {
	w, start := liveWorld(t, cfg)
	st, key, _ := machine.Load(w.dir)
	upstream, _ := url.Parse(st.Server)
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	ceil := &ceilingServer{}
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/machine/ceiling" {
			ceil.handle(rw, r)
			return
		}
		proxy.ServeHTTP(rw, r)
	}))
	t.Cleanup(ts.Close)
	st.Server = ts.URL
	if err := machine.Save(w.dir, st, key); err != nil {
		t.Fatal(err)
	}
	log := &lockedBuffer{}
	w.env.Stderr = log
	return w, ceil, log, start
}

// boardsCmd runs the boards command beside a running daemon, with its own
// output, so it shares no buffer with the daemon's.
func boardsCmd(t *testing.T, w *world, args ...string) {
	t.Helper()
	env := w.env
	var out, errOut bytes.Buffer
	env.Stdout, env.Stderr = &out, &errOut
	if code := Main(append([]string{"boards"}, args...), env); code != 0 {
		t.Fatalf("boards %v: exit %d: %s", args, code, errOut.String())
	}
}

func (s *ceilingServer) sentBoards() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, c := range s.sent {
		out = append(out, fmt.Sprint(c["boards"]))
	}
	return out
}

func changeLog(w *world) string {
	data, _ := os.ReadFile(filepath.Join(w.dir, machineconfig.ChangeLog))
	return string(data)
}

// A board added to the ceiling while the daemon runs is served without a
// restart: the runner on it, refused until then, is accepted and claims,
// and the new ceiling is reported to the server.
func TestRunTakesABoardAddedToTheCeilingWithoutARestart(t *testing.T) {
	cfg := &configServer{}
	w, ceil, log, start := ceilingLive(t, cfg)
	repo := filepath.Join(w.home, "repo")
	cfg.set(runnerJSON(21, 1, repo, "default", false), boardRunner(25, 5, repo))
	stop := start()

	waitUntil(t, "runner 25 to be refused and the ceiling reported", func() bool {
		return strings.Contains(cfg.reported(), "25 v1 rejected") && len(ceil.sentBoards()) == 1
	})
	if cfg.claimsOf("25") != 0 {
		t.Fatal("a runner on a board outside the ceiling claimed")
	}

	boardsCmd(t, w, "add", "5")
	waitUntil(t, "runner 25 to be accepted and claim", func() bool {
		return strings.Contains(cfg.reported(), "25 v1 accepted") && cfg.claimsOf("25") > 0
	})
	waitUntil(t, "the new ceiling to be reported", func() bool {
		b := ceil.sentBoards()
		return len(b) == 2 && b[1] == "[3 5]"
	})
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, log)
	}
	if b := ceil.sentBoards(); b[0] != "[3]" {
		t.Errorf("first report sent boards %s, want [3]", b[0])
	}
	changes := changeLog(w)
	for _, want := range []string{"ceiling changed at this machine: boards [3] → [3 5]", "runner r25 (#25) v1 added and accepted"} {
		if !strings.Contains(changes, want) {
			t.Errorf("the change log doesn't say %q:\n%s", want, changes)
		}
		if !strings.Contains(log.String(), want) {
			t.Errorf("the daemon's log doesn't say %q:\n%s", want, log)
		}
	}
	if !strings.Contains(log.String(), "2 of 2 runners running") {
		t.Errorf("the log doesn't say both run:\n%s", log)
	}
}

// A ceiling edited into something invalid is logged once and ignored: the
// daemon keeps the ceiling it has, and its runners run on.
func TestRunIgnoresAnInvalidCeilingEdit(t *testing.T) {
	cfg := &configServer{}
	w, ceil, log, start := ceilingLive(t, cfg)
	repo := filepath.Join(w.home, "repo")
	cfg.set(runnerJSON(21, 1, repo, "default", false))
	stop := start()
	waitUntil(t, "runner 21 to claim", func() bool { return cfg.claimsOf("21") > 0 })
	path := filepath.Join(w.dir, machine.CeilingFile)
	good, _ := os.ReadFile(path)

	for _, bad := range []string{"{not json", strings.Replace(string(good), `"agents": [`, `"agents": [], "x": [`, 1),
		strings.Replace(string(good), "acceptEdits", "everything", 1)} {
		before := strings.Count(log.String(), "the ceiling changed but isn't valid, so keeping the one in use")
		os.WriteFile(path, []byte(bad), 0o644)
		waitUntil(t, "the invalid edit to be logged", func() bool {
			return strings.Count(log.String(), "the ceiling changed but isn't valid, so keeping the one in use") == before+1
		})
		n := cfg.claimsOf("21")
		waitUntil(t, "runner 21 to claim on", func() bool { return cfg.claimsOf("21") > n+1 })
		if got := strings.Count(log.String(), "the ceiling changed but isn't valid"); got != before+1 {
			t.Fatalf("one invalid edit logged %d times", got-before)
		}
	}
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, log)
	}
	if len(ceil.sentBoards()) != 1 {
		t.Errorf("an invalid ceiling was reported: %v", ceil.sentBoards())
	}
	if strings.Contains(changeLog(w), "ceiling changed") || strings.Contains(cfg.reported(), "rejected") {
		t.Errorf("an invalid ceiling was taken in:\n%s\n%s", changeLog(w), cfg.reported())
	}
}

// A board removed from the ceiling while the daemon runs: its runner takes
// no more jobs and is reported refused; the others run on.
func TestRunStopsARunnerWhoseBoardIsRemovedFromTheCeiling(t *testing.T) {
	cfg := &configServer{}
	w, ceil, log, start := ceilingLive(t, cfg)
	if _, err := machine.EditCeiling(w.dir, func(c *machine.Ceiling) error { c.Boards = []int64{3, 5}; return nil }); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(w.home, "repo")
	cfg.set(runnerJSON(21, 1, repo, "default", false), boardRunner(25, 5, repo))
	stop := start()
	waitUntil(t, "both runners to claim", func() bool { return cfg.claimsOf("21") > 0 && cfg.claimsOf("25") > 0 })

	boardsCmd(t, w, "remove", "5")
	waitUntil(t, "runner 25 to be reported refused", func() bool { return strings.Contains(cfg.reported(), "25 v1 rejected") })
	waitUntil(t, "the narrower ceiling to be reported", func() bool {
		b := ceil.sentBoards()
		return len(b) == 2 && b[1] == "[3]"
	})
	time.Sleep(100 * time.Millisecond)
	n25, n21 := cfg.claimsOf("25"), cfg.claimsOf("21")
	waitUntil(t, "runner 21 to claim on", func() bool { return cfg.claimsOf("21") > n21+2 })
	if cfg.claimsOf("25") != n25 {
		t.Fatalf("runner 25 claimed after its board left the ceiling: %d → %d", n25, cfg.claimsOf("25"))
	}
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, log)
	}
	for _, want := range []string{"ceiling changed at this machine: boards [3 5] → [3]",
		"runner r25 (#25) v1 is outside this machine's ceiling now: it finishes the job it holds, then stops: board #5 is not one this machine serves"} {
		if !strings.Contains(changeLog(w), want) {
			t.Errorf("the change log doesn't say %q:\n%s", want, changeLog(w))
		}
	}
	if !strings.Contains(log.String(), "runner r25 (#25) takes no more jobs") {
		t.Errorf("the log doesn't say runner 25 stops:\n%s", log)
	}
}
