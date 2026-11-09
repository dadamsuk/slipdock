package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// fake is a Slipdock server's machine endpoints.
type fake struct {
	mu       sync.Mutex
	polls    int
	revoked  bool
	enrols   int
	lastBody map[string]string
	// config is GET /api/machine/config's answer (404 when empty), and
	// claims the runners' claims, each answered claimStatus.
	config      string
	claims      map[string]int
	claimStatus int
}

func (f *fake) start(t *testing.T) *httptest.Server {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		machineJSON := `{"id":7,"name":"box","boards":[3],"state":"enrolled"}`
		switch r.URL.Path {
		case "/api/machines/enrol":
			f.enrols++
			f.lastBody = body
			w.Write([]byte(`{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://slipdock.example.com/account/machines/approve","verification_uri_complete":"https://slipdock.example.com/account/machines/approve?user_code=ABCD-EFGH","expires_in":900,"interval":5}`))
		case "/api/machines/enrol/token":
			f.lastBody = body
			switch {
			case body["device_code"] == "dc":
				f.polls++
				if f.polls == 1 {
					w.WriteHeader(400)
					w.Write([]byte(`{"error":"authorization_pending"}`))
					return
				}
				w.Write([]byte(`{"machine_key":"sdm_key","machine":` + machineJSON + `}`))
			case body["enrolment_key"] == "sdk_good":
				f.enrols++
				w.Write([]byte(`{"machine_key":"sdm_key","machine":` + machineJSON + `}`))
			default:
				w.WriteHeader(400)
				w.Write([]byte(`{"error":"invalid_grant","error_description":"that enrolment key is unknown, used or lapsed"}`))
			}
		case "/api/machine/config":
			if f.config == "" || r.Header.Get("Authorization") != "Bearer sdm_key" {
				w.WriteHeader(404)
				return
			}
			w.Write([]byte(f.config))
		case "/api/runner/claim":
			if f.claims == nil {
				f.claims = map[string]int{}
			}
			f.claims[r.Header.Get("X-Runner-Id")]++
			w.WriteHeader(f.claimStatus)
		case "/api/machine":
			if r.Header.Get("Authorization") != "Bearer sdm_key" || f.revoked {
				w.WriteHeader(401)
				w.Write([]byte(`{"error":"unauthorized"}`))
				return
			}
			w.Write([]byte(`{"machine":` + machineJSON + `}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(ts.Close)
	return ts
}

type world struct {
	env            Env
	out, errOut    *bytes.Buffer
	dir, home      string
	opened         []string
	ran            []string
	runErr         map[string]error
	paths          map[string]bool
	outputs        map[string]string
	outputErr      map[string]error
	sleeps         int
	stopAfterSleep int
}

func newWorld(t *testing.T) *world {
	w := &world{
		out: &bytes.Buffer{}, errOut: &bytes.Buffer{},
		dir: filepath.Join(t.TempDir(), "machine"), home: t.TempDir(),
		runErr:    map[string]error{},
		paths:     map[string]bool{"git": true, "gh": true, "claude": true, "systemctl": true},
		outputs:   map[string]string{"claude": "2.1.0 (Claude Code)\n", "gh": "Logged in\n"},
		outputErr: map[string]error{},
	}
	w.env = Env{
		Stdin:  strings.NewReader(""),
		Stdout: w.out, Stderr: w.errOut,
		Getenv:     func(k string) string { return map[string]string{machine.HomeEnv: w.dir}[k] },
		Hostname:   func() (string, error) { return "box", nil },
		UserHome:   func() (string, error) { return w.home, nil },
		Executable: func() (string, error) { return filepath.Join(w.home, "bin", "slipdock-runner"), nil },
		GOOS:       "linux", GOARCH: "amd64",
		OSName:      func() string { return "linux (WSL)" },
		OpenBrowser: func(u string) error { w.opened = append(w.opened, u); return nil },
		LookPath: func(name string) (string, error) {
			if w.paths[name] {
				return "/usr/bin/" + name, nil
			}
			return "", errors.New("not found")
		},
		Run: func(name string, args ...string) error {
			line := name + " " + strings.Join(args, " ")
			w.ran = append(w.ran, line)
			return w.runErr[line]
		},
		Output: func(name string, args ...string) (string, error) { return w.outputs[name], w.outputErr[name] },
		Sleep: func(ctx context.Context, d time.Duration) error {
			w.sleeps++
			if w.stopAfterSleep > 0 && w.sleeps >= w.stopAfterSleep {
				return context.Canceled
			}
			return nil
		},
		HTTP:    &http.Client{Timeout: 5 * time.Second},
		Context: func() (context.Context, context.CancelFunc) { return context.WithCancel(context.Background()) },
		Account: func() string { return "builder" },
	}
	return w
}

func (w *world) main(args ...string) int {
	w.out.Reset()
	w.errOut.Reset()
	return Main(args, w.env)
}

func TestInitByDeviceCode(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	w := newWorld(t)

	if code := w.main("init", "--as-me", "--server", ts.URL); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"This machine: box (linux (WSL), amd64)", "Fingerprint:  ", "ABCD-EFGH",
		"/account/machines/approve", "Check the page shows the fingerprint", "Enrolled as box (machine #7)",
		"Proposed ceiling", "acceptEdits", "60 minutes", "#3"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if len(w.opened) != 1 || !strings.Contains(w.opened[0], "user_code=ABCD-EFGH") {
		t.Fatalf("opens the approval page with the code: %v", w.opened)
	}
	if f.lastBody["device_code"] != "dc" || f.polls != 2 {
		t.Fatalf("polled until approved: %d polls", f.polls)
	}

	st, key, err := machine.Load(w.dir)
	if err != nil || key != "sdm_key" || st.MachineID != 7 || st.EnrolledVia != "device" || st.Server != ts.URL {
		t.Fatalf("saved %+v %q %v", st, key, err)
	}
	if runtime.GOOS != "windows" {
		fi, _ := os.Stat(filepath.Join(w.dir, machine.KeyFile))
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("machine key mode %o", fi.Mode().Perm())
		}
	}
	c, err := machine.LoadCeiling(w.dir)
	if err != nil || c.Roots[0] != filepath.Join(w.home, "src") || c.Agents[0] != "claude" || c.Boards[0] != 3 {
		t.Fatalf("ceiling %+v %v", c, err)
	}
	id, _ := machine.LoadOrCreateIdentity(w.dir)
	if !strings.Contains(out, id.Fingerprint()) {
		t.Fatal("init prints the fingerprint it keeps")
	}
}

func TestInitRefusesToReplaceWithoutReplace(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	w := newWorld(t)
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	_, firstKey, _ := machine.Load(w.dir)

	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good"); code != 1 {
		t.Fatalf("a second init must refuse: exit %d", code)
	}
	if !strings.Contains(w.errOut.String(), "already enrolled (box on "+ts.URL+"). Pass --replace") {
		t.Fatalf("says why: %s", w.errOut)
	}
	if f.enrols != 1 {
		t.Fatal("a refused init must not ask the server")
	}
	if _, key, _ := machine.Load(w.dir); key != firstKey {
		t.Fatal("the key must be untouched")
	}

	// A person's own ceiling survives --replace.
	c, _ := machine.LoadCeiling(w.dir)
	c.MaxTimeoutMinutes = 15
	if err := machine.SaveCeiling(w.dir, c); err != nil {
		t.Fatal(err)
	}
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good", "--replace"); code != 0 {
		t.Fatalf("--replace: exit %d: %s", code, w.errOut)
	}
	if got, _ := machine.LoadCeiling(w.dir); got.MaxTimeoutMinutes != 15 {
		t.Fatalf("ceiling replaced: %+v", got)
	}
	if !strings.Contains(w.out.String(), "Kept ceiling") {
		t.Fatal(w.out.String())
	}
}

func TestInitWithAKey(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	w := newWorld(t)
	code := w.main("init", "--as-me", "--server", ts.URL, "--key", " sdk_good ", "--root", w.home, "--agent", "claude",
		"--agent", "codex", "--max-mode", "plan", "--max-timeout", "30")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if f.lastBody["enrolment_key"] != "sdk_good" || f.lastBody["fingerprint"] == "" || f.lastBody["os"] != "linux (WSL)" {
		t.Fatalf("body %v", f.lastBody)
	}
	if len(w.opened) != 0 || f.polls != 0 {
		t.Fatal("a key needs no approval page and no polling")
	}
	c, _ := machine.LoadCeiling(w.dir)
	if c.Roots[0] != w.home || len(c.Agents) != 2 || c.MaxPermissionMode != "plan" || c.MaxTimeoutMinutes != 30 {
		t.Fatalf("flags make the ceiling: %+v", c)
	}
	st, _, _ := machine.Load(w.dir)
	if st.EnrolledVia != "key" {
		t.Fatal(st)
	}
}

func TestInitFailures(t *testing.T) {
	f := &fake{}
	ts := f.start(t)

	w := newWorld(t)
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_used"); code != 1 ||
		!strings.Contains(w.errOut.String(), "enrolment failed: invalid_grant") {
		t.Fatalf("a used key: %d %s", code, w.errOut)
	}
	if machine.Enrolled(w.dir) {
		t.Fatal("a failed enrolment saves no key")
	}

	before := f.enrols
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good", "--max-mode", "yolo"); code != 1 ||
		!strings.Contains(w.errOut.String(), "max_permission_mode") {
		t.Fatalf("a bad ceiling flag: %d %s", code, w.errOut)
	}
	if f.enrols != before {
		t.Fatal("a bad ceiling flag is caught before enrolling")
	}

	if code := w.main("init", "--as-me", "--server", "http://slipdock.example.com", "--key", "k"); code != 1 ||
		!strings.Contains(w.errOut.String(), "plain http") {
		t.Fatalf("plain http to another host: %d %s", code, w.errOut)
	}
	if code := w.main("init", "--as-me", "--server", "ftp://x", "--key", "k"); code != 1 ||
		!strings.Contains(w.errOut.String(), "is not a server address") {
		t.Fatalf("not a server: %d %s", code, w.errOut)
	}
	if code := w.main("init", "--as-me", "--bogus"); code != 2 {
		t.Fatalf("an unknown flag is a usage error: %d", code)
	}
	if code := w.main("init", "--as-me", "extra"); code != 2 {
		t.Fatalf("a stray argument is a usage error: %d", code)
	}
}

func TestInitAsksForTheServer(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	w := newWorld(t)
	w.env.Stdin = strings.NewReader(ts.URL + "/\n")
	if code := w.main("init", "--as-me", "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(w.out.String(), "Slipdock server [https://app.slipdock.us]: ") {
		t.Fatal(w.out.String())
	}
	if st, _, _ := machine.Load(w.dir); st.Server != ts.URL {
		t.Fatalf("server %q: trailing slash dropped", st.Server)
	}

	// Nothing typed: the default.
	if got, err := serverURL("", Env{Stdin: strings.NewReader("\n"), Stdout: &bytes.Buffer{}}); err != nil || got != DefaultServer {
		t.Fatalf("%q %v", got, err)
	}
}

func TestInitDeviceRefusedOrExpired(t *testing.T) {
	for code, want := range map[string]string{"access_denied": "refused", "expired_token": "expired"} {
		ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/api/machines/enrol" {
				rw.Write([]byte(`{"device_code":"dc","user_code":"X","verification_uri":"https://slipdock.example.com/a","interval":1}`))
				return
			}
			rw.WriteHeader(400)
			rw.Write([]byte(`{"error":"` + code + `"}`))
		}))
		w := newWorld(t)
		if c := w.main("init", "--as-me", "--server", ts.URL, "--no-browser"); c != 1 || !strings.Contains(w.errOut.String(), want) {
			t.Errorf("%s: exit %d %s", code, c, w.errOut)
		}
		if len(w.opened) != 0 {
			t.Error("--no-browser opens nothing")
		}
		ts.Close()
	}
}

func enrolled(t *testing.T) (*world, *fake) {
	f := &fake{}
	ts := f.start(t)
	w := newWorld(t)
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good", "--root", w.home); code != 0 {
		t.Fatalf("init: %s", w.errOut)
	}
	return w, f
}

func TestShowFillsTheContract(t *testing.T) {
	w, _ := enrolled(t)
	if code := w.main("show"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	id, _ := machine.LoadOrCreateIdentity(w.dir)
	for _, want := range []string{"trust contract", "Machine:       box (#7)", id.Fingerprint(),
		"Working directories inside: " + w.home, "Jobs run as:   builder", "Run a command on this machine",
		filepath.Join(w.dir, machine.CeilingFile)} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}

	empty := newWorld(t)
	if code := empty.main("show"); code != 1 || !strings.Contains(empty.errOut.String(), "not enrolled") {
		t.Fatalf("unenrolled: %d %s", code, empty.errOut)
	}
	os.Remove(filepath.Join(w.dir, machine.CeilingFile))
	if code := w.main("show"); code != 1 || !strings.Contains(w.errOut.String(), "the ceiling") {
		t.Fatalf("no ceiling: %d %s", code, w.errOut)
	}
}

func TestDoctor(t *testing.T) {
	w, f := enrolled(t)
	if code := w.main("doctor"); code != 0 {
		t.Fatalf("exit %d:\n%s%s", code, w.out, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"ok    enrolled: box (machine #7)", "ok    agent claude: 2.1.0 (Claude Code)",
		"ok    the server knows this machine: box, serving boards #3", "ok    gh: logged in",
		"warn  service: not installed", "This machine is ready."} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if runtime.GOOS != "windows" && !strings.Contains(out, "ok    machine key is readable only by you") {
		t.Error(out)
	}

	// Each failure says what to do.
	w.paths["git"] = false
	w.paths["claude"] = false
	w.outputErr["gh"] = errors.New("exit 1")
	w.outputs["gh"] = "You are not logged into any GitHub hosts\n"
	f.revoked = true
	if runtime.GOOS != "windows" {
		os.Chmod(filepath.Join(w.dir, machine.KeyFile), 0o644)
	}
	if code := w.main("doctor"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	out = w.out.String()
	for _, want := range []string{"FAIL  git: not on the PATH", "FAIL  agent claude: not on the PATH",
		"FAIL  the server knows this machine: it refuses the machine key", "warn  gh: not logged in (gh auth login): You are not"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if runtime.GOOS != "windows" && !strings.Contains(out, "is mode 644: chmod 600") {
		t.Error(out)
	}
	if !strings.Contains(w.errOut.String(), "check(s) failed") {
		t.Error(w.errOut.String())
	}
}

func TestDoctorUnenrolledAndBrokenCeiling(t *testing.T) {
	w := newWorld(t)
	if code := w.main("doctor"); code != 1 || !strings.Contains(w.out.String(), "FAIL  enrolled: this machine is not enrolled") {
		t.Fatalf("%d %s", code, w.out)
	}
	w, _ = enrolled(t)
	os.WriteFile(filepath.Join(w.dir, machine.CeilingFile), []byte("{}"), 0o644)
	w.paths["gh"] = false
	w.outputErr["claude"] = errors.New("exit 2")
	if code := w.main("doctor"); code != 1 || !strings.Contains(w.out.String(), "FAIL  ceiling") ||
		!strings.Contains(w.out.String(), "warn  gh: not on the PATH") {
		t.Fatalf("%d %s", code, w.out)
	}
}

func TestDoctorAgents(t *testing.T) {
	w := newWorld(t)
	if c := agentCheck("mytool", w.env); c.status != ok || !strings.Contains(c.detail, "custom command") {
		t.Fatal(c)
	}
	w.outputErr["claude"] = errors.New("exit 1")
	w.outputs["claude"] = "broken install\nmore"
	if c := agentCheck("claude", w.env); c.status != fail || c.detail != "`claude --version` failed: broken install" {
		t.Fatal(c)
	}
}

func TestServicePrintAndInstall(t *testing.T) {
	w, _ := enrolled(t)
	if code := w.main("service", "print"); code != 0 {
		t.Fatalf("%d %s", code, w.errOut)
	}
	unit := filepath.Join(w.home, ".config", "systemd", "user", "slipdock-machine.service")
	if !strings.Contains(w.out.String(), "# "+unit) || !strings.Contains(w.out.String(), "run --home") {
		t.Fatal(w.out.String())
	}

	if code := w.main("service", "install"); code != 0 {
		t.Fatalf("%d %s", code, w.errOut)
	}
	data, err := os.ReadFile(unit)
	if err != nil || !strings.Contains(string(data), systemdQuoted(w.dir)) {
		t.Fatalf("unit written with the daemon's directory: %v\n%s", err, data)
	}
	if len(w.ran) != 3 || w.ran[2] != "systemctl --user restart slipdock-machine.service" {
		t.Fatalf("ran %v", w.ran)
	}
	if !strings.Contains(w.out.String(), "journalctl --user -u slipdock-machine") {
		t.Fatal(w.out.String())
	}
	if code := w.main("doctor"); !strings.Contains(w.out.String(), "ok    service: "+unit) {
		t.Fatalf("doctor sees the service: %d\n%s", code, w.out)
	}

	w.ran = nil
	if code := w.main("service", "uninstall"); code != 0 {
		t.Fatalf("%d %s", code, w.errOut)
	}
	if _, err := os.Stat(unit); !os.IsNotExist(err) {
		t.Fatal("uninstall removes the unit")
	}
	if w.ran[0] != "systemctl --user disable --now slipdock-machine.service" {
		t.Fatal(w.ran)
	}
}

func TestServiceOnEachOS(t *testing.T) {
	w, _ := enrolled(t)
	w.env.GOOS = "darwin"
	if code := w.main("service", "print"); code != 0 || !strings.Contains(w.out.String(), "us.slipdock.machine") {
		t.Fatalf("%d %s", code, w.out)
	}
	w.env.GOOS = "windows"
	if code := w.main("service", "print"); code != 0 || !strings.Contains(w.out.String(), "Task Scheduler") {
		t.Fatalf("%d %s", code, w.out)
	}
	w.env.GOOS = "linux"
	w.paths["systemctl"] = false
	if code := w.main("service", "install"); code != 1 || !strings.Contains(w.errOut.String(), "no systemd") {
		t.Fatalf("%d %s", code, w.errOut)
	}
}

func TestServiceErrors(t *testing.T) {
	w := newWorld(t)
	if code := w.main("service"); code != 2 {
		t.Fatal(code)
	}
	if code := w.main("service", "restart"); code != 2 {
		t.Fatal(code)
	}
	if code := w.main("service", "install"); code != 1 || !strings.Contains(w.errOut.String(), "not enrolled") {
		t.Fatalf("an unenrolled machine installs no service: %d %s", code, w.errOut)
	}
	w, _ = enrolled(t)
	w.runErr["systemctl --user enable slipdock-machine.service"] = errors.New("exit 1")
	if code := w.main("service", "install"); code != 1 || !strings.Contains(w.errOut.String(), "systemctl --user enable") {
		t.Fatalf("%d %s", code, w.errOut)
	}
}

func TestRunStopsWhenRevokedOrAskedTo(t *testing.T) {
	w, f := enrolled(t)
	logFile := filepath.Join(t.TempDir(), "daemon.log")

	// Asked to stop (the context ends during a wait): exits cleanly.
	w.stopAfterSleep = 2
	if code := w.main("run", "--log", logFile); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	log, _ := os.ReadFile(logFile)
	if !strings.Contains(string(log), "enrolled as box, serving boards #3") || !strings.Contains(string(log), "stopping") {
		t.Fatalf("log:\n%s", log)
	}

	// Revoked: exits with the reason.
	// (Stopped after five waits at most, so a daemon that ignored the
	// revocation fails this rather than hanging it.)
	w.sleeps, w.stopAfterSleep = 0, 5
	f.revoked = true
	if code := w.main("run"); code != 1 || !strings.Contains(w.errOut.String(), "revoked") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}

	empty := newWorld(t)
	if code := empty.main("run"); code != 1 || !strings.Contains(empty.errOut.String(), "not enrolled") {
		t.Fatalf("%d %s", code, empty.errOut)
	}
}

func TestRunRunsTheMachinesRunners(t *testing.T) {
	w, f := enrolled(t)
	inside := filepath.Join(w.home, "repo")
	f.config = `{"version":4,"runners":[
		{"id":21,"name":"builder","board_id":3,"pool":"default","config_version":2,
		 "config":{"agent":"claude","directory":` + jsonString(inside) + `,"permission_mode":"acceptEdits","timeout_minutes":30,"executor":"me","worktree":"auto"}},
		{"id":22,"name":"wide","board_id":3,"pool":"default","config_version":1,
		 "config":{"agent":"claude","directory":` + jsonString(filepath.Join(filepath.Dir(w.home), "elsewhere")) + `,"permission_mode":"acceptEdits","timeout_minutes":30,"executor":"me"}}]}`
	// The server takes the machine's key away while its runner claims: run
	// stops everything and says why.
	f.claimStatus = 401
	logFile := filepath.Join(t.TempDir(), "daemon.log")
	if code := w.main("run", "--log", logFile); code != 1 || !strings.Contains(w.errOut.String(), "revoked") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	log, _ := os.ReadFile(logFile)
	for _, want := range []string{
		"config version 4: 1 of 2 runners running",
		"runner wide (#22) is outside this machine's ceiling, so it doesn't run",
		"runner builder (#21): the server refused the runner (HTTP 401)",
	} {
		if !strings.Contains(string(log), want) {
			t.Errorf("the log doesn't say %q:\n%s", want, log)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.claims["21"] != 1 || f.claims["22"] != 0 {
		t.Fatalf("claims = %v: only the runner inside the ceiling claims", f.claims)
	}
}

func TestRunRefusesABrokenLocalFile(t *testing.T) {
	w, _ := enrolled(t)
	if err := os.WriteFile(filepath.Join(w.dir, machine.LocalFile), []byte(`{"command":"x"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := w.main("run"); code != 1 || !strings.Contains(w.errOut.String(), "the local file") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestRunRetriesAnUnreachableServer(t *testing.T) {
	w, _ := enrolled(t)
	st, key, _ := machine.Load(w.dir)
	st.Server = "http://127.0.0.1:1"
	if err := machine.Save(w.dir, st, key); err != nil {
		t.Fatal(err)
	}
	w.stopAfterSleep = 2
	if code := w.main("run"); code != 0 || strings.Count(w.errOut.String(), "can't reach the server") != 2 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
}

func TestHelpVersionAndUnknown(t *testing.T) {
	w := newWorld(t)
	if code := w.main(); code != 2 || !strings.Contains(w.out.String(), "Usage:") {
		t.Fatal(code)
	}
	if code := w.main("help"); code != 0 {
		t.Fatal(code)
	}
	if code := w.main("version"); code != 0 || w.out.String() != "slipdock-runner dev (linux/amd64)\n" {
		t.Fatalf("%q", w.out.String())
	}
	if code := w.main("frobnicate"); code != 2 || !strings.Contains(w.errOut.String(), `unknown command "frobnicate"`) {
		t.Fatal(code)
	}
	if code := w.main("show", "-h"); code != 2 {
		t.Fatal(code)
	}
}

func TestHomeFlagOverridesTheEnvironment(t *testing.T) {
	w, _ := enrolled(t)
	elsewhere := newWorld(t)
	elsewhere.env.Getenv = func(string) string { return "" }
	if code := elsewhere.main("show", "--home", w.dir); code != 0 || !strings.Contains(elsewhere.out.String(), "box (#7)") {
		t.Fatalf("%d %s", code, elsewhere.errOut)
	}
}

func TestOpenBrowserPerOS(t *testing.T) {
	for goos, want := range map[string]string{"darwin": "open", "windows": "rundll32", "linux": "xdg-open"} {
		var got string
		_ = openBrowser(goos, "https://slipdock.example.com", func(name string, args ...string) error { got = name; return nil })
		if got != want {
			t.Errorf("%s: %s", goos, got)
		}
	}
}

// systemdQuoted is how the unit spells a path: quoted, backslashes doubled.
func systemdQuoted(p string) string {
	return `"` + strings.ReplaceAll(p, `\`, `\\`) + `"`
}
