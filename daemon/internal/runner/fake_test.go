package runner

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// TestMain doubles as the agent and the hooks: run as `<test binary>
// helper <mode> …`, it does what the mode says instead of testing, so the
// jobs run a real process on every OS.
func TestMain(m *testing.M) {
	if len(os.Args) >= 3 && os.Args[1] == "helper" {
		os.Exit(helper(os.Args[2], os.Args[3:]))
	}
	os.Exit(m.Run())
}

func helper(mode string, args []string) int {
	switch mode {
	case "agent":
		// Writes what it was given to $HELPER_OUT, says hello, and exits
		// with $HELPER_EXIT.
		wd, _ := os.Getwd()
		wd, _ = filepath.EvalSymlinks(wd)
		var b strings.Builder
		fmt.Fprintf(&b, "dir=%s\n", wd)
		fmt.Fprintf(&b, "pwd-matches=%v\n", os.Getenv("PWD") == "" || sameDir(os.Getenv("PWD"), wd))
		for _, a := range args {
			fmt.Fprintf(&b, "arg=%s\n", strings.ReplaceAll(a, "\n", `\n`))
		}
		for _, e := range os.Environ() {
			if strings.HasPrefix(e, "SLIPDOCK_") || strings.HasPrefix(e, "CLAUDE_CODE_") {
				fmt.Fprintf(&b, "env=%s\n", strings.ReplaceAll(e, "\n", `\n`))
			}
		}
		_ = os.WriteFile(os.Getenv("HELPER_OUT"), []byte(b.String()), 0o600)
		fmt.Println("hello from the agent")
		if tx := os.Getenv("HELPER_TRANSCRIPT"); tx != "" {
			_ = os.MkdirAll(filepath.Dir(tx), 0o700)
			_ = os.WriteFile(tx, []byte(os.Getenv("HELPER_TRANSCRIPT_BODY")), 0o600)
		}
		code, _ := strconv.Atoi(os.Getenv("HELPER_EXIT"))
		return code
	case "tree":
		// Starts a child that ticks into $HELPER_TICK, then waits forever:
		// stopping the job must stop both.
		child := exec.Command(os.Args[0], "helper", "tick")
		if err := child.Start(); err != nil {
			fmt.Println("child:", err)
			return 1
		}
		fmt.Println("started the tree")
		time.Sleep(time.Hour)
		return 0
	case "tick":
		for i := 0; ; i++ {
			_ = os.WriteFile(os.Getenv("HELPER_TICK"), []byte(strconv.Itoa(i)), 0o600)
			time.Sleep(20 * time.Millisecond)
		}
	case "hook":
		// Appends "<name> <exit> <status> <job>" to $HELPER_HOOKS and exits
		// with $HELPER_HOOK_EXIT_<name>.
		name := args[0]
		f, _ := os.OpenFile(os.Getenv("HELPER_HOOKS"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		fmt.Fprintf(f, "%s exit=%s status=%s job=%s\n", name, os.Getenv("SLIPDOCK_EXIT"), os.Getenv("SLIPDOCK_STATUS"), os.Getenv("SLIPDOCK_JOB_ID"))
		f.Close()
		fmt.Println("hook", name, "ran")
		code, _ := strconv.Atoi(os.Getenv("HELPER_HOOK_EXIT_" + name))
		return code
	}
	return 99
}

// fakeJob is a job the fake server hands out.
type fakeJob struct {
	runner  int64
	id      int64
	kind    string
	card    int64
	profile string
	prompt  string
	pr, sha string
}

type finished struct {
	exit           int
	status, merged string
	body           string
}

// server is a Slipdock server's runner protocol.
type server struct {
	t  *testing.T
	ts *httptest.Server

	mu          sync.Mutex
	jobs        []fakeJob
	claims      map[int64]int
	claimHeader map[int64]http.Header
	refuse      map[int64]int // runner → status for its claims
	cancel      map[int64]bool
	lost        map[int64]bool
	beats       map[int64][]string
	finishes    map[int64]finished
	transcript  map[int64][]string
	txCap       int
	config      string
}

func newServer(t *testing.T) *server {
	s := &server{t: t, claims: map[int64]int{}, claimHeader: map[int64]http.Header{}, refuse: map[int64]int{},
		cancel: map[int64]bool{}, lost: map[int64]bool{}, beats: map[int64][]string{},
		finishes: map[int64]finished{}, transcript: map[int64][]string{}}
	s.ts = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.ts.Close)
	return s
}

func (s *server) add(j fakeJob) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.jobs = append(s.jobs, j)
}

func (s *server) handle(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if r.Header.Get("Authorization") != "Bearer sdm_test_key" {
		w.WriteHeader(401)
		fmt.Fprintln(w, "unauthorized: the machine key is unknown or the machine is revoked")
		return
	}
	if r.URL.Path == "/api/machine/config" {
		s.mu.Lock()
		cfg := s.config
		s.mu.Unlock()
		if cfg == "" {
			w.WriteHeader(404)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, cfg)
		return
	}
	rid, _ := strconv.ParseInt(r.Header.Get("X-Runner-Id"), 10, 64)
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.URL.Path == "/api/runner/claim":
		s.claims[rid]++
		s.claimHeader[rid] = r.Header.Clone()
		if code := s.refuse[rid]; code != 0 {
			w.WriteHeader(code)
			fmt.Fprintln(w, "refused")
			return
		}
		for i, j := range s.jobs {
			if j.runner != rid {
				continue
			}
			s.jobs = append(s.jobs[:i], s.jobs[i+1:]...)
			h := w.Header()
			h.Set("X-Job-Id", strconv.FormatInt(j.id, 10))
			h.Set("X-Job-Kind", j.kind)
			if j.card != 0 {
				h.Set("X-Card-Id", strconv.FormatInt(j.card, 10))
				h.Set("X-Card-Url", fmt.Sprintf("https://slipdock.example.com/boards/3/cards/%d", j.card))
			}
			h.Set("X-Board-Id", "3")
			h.Set("X-Lease-Seconds", "90")
			if j.profile != "" {
				h.Set("X-Card-Profile", j.profile)
			}
			if j.pr != "" {
				h.Set("X-Merge-PR", j.pr)
				h.Set("X-Merge-Commit", j.sha)
			}
			fmt.Fprint(w, j.prompt)
			return
		}
		s.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
		s.mu.Lock()
		w.WriteHeader(204)
	case strings.HasSuffix(r.URL.Path, "/heartbeat"):
		id := jobID(r.URL.Path)
		s.beats[id] = append(s.beats[id], string(body))
		switch {
		case s.lost[id]:
			w.WriteHeader(404)
			fmt.Fprintln(w, "no such job for this runner")
		case s.cancel[id]:
			fmt.Fprintln(w, "cancel")
		default:
			fmt.Fprintln(w, "ok")
		}
	case strings.HasSuffix(r.URL.Path, "/transcript"):
		id := jobID(r.URL.Path)
		from, _ := strconv.Atoi(r.URL.Query().Get("from"))
		if from != len(s.transcript[id]) {
			w.WriteHeader(409)
			fmt.Fprintf(w, "from %d\n", len(s.transcript[id]))
			return
		}
		for _, line := range strings.SplitAfter(string(body), "\n") {
			if line != "" {
				s.transcript[id] = append(s.transcript[id], strings.TrimSuffix(line, "\n"))
			}
		}
		if s.txCap > 0 && len(s.transcript[id]) >= s.txCap {
			fmt.Fprintf(w, "capped %d\n", len(s.transcript[id]))
			return
		}
		fmt.Fprintf(w, "ok %d\n", len(s.transcript[id]))
	case strings.HasSuffix(r.URL.Path, "/finish"):
		id := jobID(r.URL.Path)
		exit, _ := strconv.Atoi(r.URL.Query().Get("exit"))
		s.finishes[id] = finished{exit, r.URL.Query().Get("status"), r.URL.Query().Get("merged"), string(body)}
		fmt.Fprintln(w, "ok done")
	default:
		w.WriteHeader(404)
	}
}

func jobID(path string) int64 {
	parts := strings.Split(path, "/")
	id, _ := strconv.ParseInt(parts[len(parts)-2], 10, 64)
	return id
}

func (s *server) finish(id int64) (finished, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.finishes[id]
	return f, ok
}

// waitFor polls cond until it holds, failing the test after a while.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// self is the test binary as a command: the helper's mode, then its args.
func self(mode string, args ...string) machine.Command {
	path, _ := filepath.Abs(os.Args[0])
	return machine.Command{Path: path, Args: append([]string{"helper", mode}, args...)}
}

// rig is a worker against the fake server, with its own directories.
type rig struct {
	t      *testing.T
	srv    *server
	w      *Worker
	dir    string // the runner's working directory
	out    string // what the agent was given
	hooks  string // which hooks ran
	logged *logBuf
}

type logBuf struct {
	mu    sync.Mutex
	lines []string
}

func (l *logBuf) logf(format string, a ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, fmt.Sprintf(format, a...))
}

func (l *logBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Join(l.lines, "\n")
}

func newRig(t *testing.T, cfg Config) *rig {
	t.Helper()
	srv := newServer(t)
	base := t.TempDir()
	r := &rig{t: t, srv: srv, dir: filepath.Join(base, "src", "repo"), out: filepath.Join(base, "agent.out"),
		hooks: filepath.Join(base, "hooks.out"), logged: &logBuf{}}
	if err := os.MkdirAll(r.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HELPER_OUT", r.out)
	t.Setenv("HELPER_HOOKS", r.hooks)
	t.Setenv("HELPER_EXIT", "0")
	if cfg.Agent == "" {
		cfg.Agent = "claude"
	}
	if cfg.PermissionMode == "" {
		cfg.PermissionMode = "acceptEdits"
	}
	if cfg.TimeoutMinutes == 0 {
		cfg.TimeoutMinutes = 60
	}
	if cfg.Worktree == "" {
		cfg.Worktree = "off"
	}
	cfg.Directory = r.dir
	cfg.Executor = "me"
	home := filepath.Join(base, "home")
	r.w = &Worker{
		Runner:  Runner{ID: 11, Name: "builder", BoardID: 3, Pool: "default", Config: cfg},
		Client:  &Client{Server: srv.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{}},
		Local:   machine.Local{Agents: map[string]machine.Command{"claude": self("agent"), "codex": self("agent")}},
		Version: "test",
		JobsDir: filepath.Join(base, "jobs"),
		Home:    home,
		Logf:    r.logged.logf,
		Getenv:  func(string) string { return "" },
		LookPath: func(name string) (string, error) {
			return "", fmt.Errorf("%s: not found", name)
		},
		Wait: 0, Heartbeat: 30 * time.Millisecond, TranscriptEvery: 30 * time.Millisecond,
		Grace: 200 * time.Millisecond, Tick: 10 * time.Millisecond,
	}
	return r
}

// run runs the worker until the job has finished (or done says so), then
// stops it.
func (r *rig) run(done func() bool) {
	r.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan error, 1)
	go func() { stopped <- r.w.Run(ctx) }()
	waitFor(r.t, "the job", done)
	cancel()
	if err := <-stopped; err != nil {
		r.t.Fatalf("Run: %v", err)
	}
}

func (r *rig) runJob(j fakeJob) finished {
	r.t.Helper()
	j.runner = r.w.Runner.ID
	r.srv.add(j)
	r.run(func() bool { _, ok := r.srv.finish(j.id); return ok })
	f, _ := r.srv.finish(j.id)
	return f
}

func (r *rig) agentSaw() string {
	data, err := os.ReadFile(r.out)
	if err != nil {
		return ""
	}
	return string(data)
}

func (r *rig) hooksRan() string {
	data, _ := os.ReadFile(r.hooks)
	return string(data)
}

func sameDir(a, b string) bool {
	a, _ = filepath.EvalSymlinks(a)
	b, _ = filepath.EvalSymlinks(b)
	return a == b
}

// realPath is path with its symlinks (and, on Windows, short names) resolved.
func realPath(t *testing.T, path string) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return p
}
