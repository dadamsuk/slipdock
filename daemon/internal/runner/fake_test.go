package runner

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

// TestMain doubles as the agent and the hooks: run as `<test binary>
// helper <mode> …`, it does what the mode says instead of testing, so the
// jobs run a real process on every OS. Run as `<test binary> confine …`,
// it is slipdock-runner's confine, which a confined job starts through.
func TestMain(m *testing.M) {
	if len(os.Args) >= 3 && os.Args[1] == "helper" {
		os.Exit(helper(os.Args[2], os.Args[3:]))
	}
	if len(os.Args) >= 2 && os.Args[1] == "confine" {
		os.Exit(executor.ConfineMain(os.Args[2:], os.Stderr))
	}
	os.Exit(m.Run())
}

func helper(mode string, args []string) int {
	switch mode {
	case "agent":
		// Writes what it was given to $HELPER_OUT, says hello, and exits
		// with $HELPER_EXIT; asked for --version, see version.
		if len(args) > 0 && args[len(args)-1] == "--version" {
			return version()
		}
		wd, _ := os.Getwd()
		wd, _ = filepath.EvalSymlinks(wd)
		var b strings.Builder
		fmt.Fprintf(&b, "dir=%s\n", wd)
		fmt.Fprintf(&b, "pwd-matches=%v\n", os.Getenv("PWD") == "" || sameDir(os.Getenv("PWD"), wd))
		for _, a := range args {
			fmt.Fprintf(&b, "arg=%s\n", strings.ReplaceAll(a, "\n", `\n`))
		}
		for _, e := range os.Environ() {
			if strings.HasPrefix(e, "SLIPDOCK_") || strings.HasPrefix(e, "CLAUDE_CODE_") || strings.HasPrefix(e, "RUNNER_ENV_") || (os.Getenv("HELPER_SHOW_PATH") != "" && strings.HasPrefix(e, "PATH=")) {
				fmt.Fprintf(&b, "env=%s\n", strings.ReplaceAll(e, "\n", `\n`))
			}
		}
		if tmp := os.Getenv("TMPDIR"); os.Getenv("HELPER_SCRATCH") != "" && tmp != "" {
			if err := os.WriteFile(filepath.Join(tmp, "scratch"), []byte("x"), 0o600); err == nil {
				b.WriteString("scratch=writable\n")
			}
		}
		_ = os.WriteFile(os.Getenv("HELPER_OUT"), []byte(b.String()), 0o600)
		fmt.Println("hello from the agent")
		if say := os.Getenv("HELPER_SAY"); say != "" {
			fmt.Println(say)
		}
		if tx := os.Getenv("HELPER_TRANSCRIPT"); tx != "" {
			_ = os.MkdirAll(filepath.Dir(tx), 0o700)
			_ = os.WriteFile(tx, []byte(os.Getenv("HELPER_TRANSCRIPT_BODY")), 0o600)
		}
		code, _ := strconv.Atoi(os.Getenv("HELPER_EXIT"))
		return code
	case "tree", "stubborn-tree":
		// Starts a child that ticks into $HELPER_TICK, then waits forever:
		// stopping the job must stop both. A stubborn tree's child ignores
		// SIGTERM, so only the forced stop after the grace ends it.
		tick := "tick"
		if mode == "stubborn-tree" {
			tick = "stubborn-tick"
		}
		child := exec.Command(os.Args[0], "helper", tick)
		if err := child.Start(); err != nil {
			fmt.Println("child:", err)
			return 1
		}
		fmt.Println("started the tree")
		time.Sleep(time.Hour)
		return 0
	case "tick", "stubborn-tick":
		if mode == "stubborn-tick" {
			signal.Ignore(syscall.SIGTERM)
		}
		for i := 0; ; i++ {
			_ = os.WriteFile(os.Getenv("HELPER_TICK"), []byte(strconv.Itoa(i)), 0o600)
			time.Sleep(20 * time.Millisecond)
		}
	case "hook":
		// Appends "<name> <exit> <status> <job>" to $HELPER_HOOKS (and
		// $RUNNER_ENV_PROBE, when it is set) and exits with
		// $HELPER_HOOK_EXIT_<name>.
		name := args[0]
		f, _ := os.OpenFile(os.Getenv("HELPER_HOOKS"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		probe := ""
		if v := os.Getenv("RUNNER_ENV_PROBE"); v != "" {
			probe = " probe=" + v
		}
		fmt.Fprintf(f, "%s exit=%s status=%s job=%s%s\n", name, os.Getenv("SLIPDOCK_EXIT"), os.Getenv("SLIPDOCK_STATUS"), os.Getenv("SLIPDOCK_JOB_ID"), probe)
		f.Close()
		fmt.Println("hook", name, "ran")
		code, _ := strconv.Atoi(os.Getenv("HELPER_HOOK_EXIT_" + name))
		return code
	case "ran-unwritten":
		// Runs and says so, and as whom, then exits 0 without writing:
		// an executor check that never says writable.
		fmt.Println("ran")
		fmt.Println("someone")
		return 0
	case "refuse":
		// An executor that won't run the command: sudo's refusal.
		fmt.Fprintln(os.Stderr, "sudo: a password is required")
		return 1
	}
	return 99
}

// version is the agent's --version, as a probe runs it: it writes where it
// ran, its TMPDIR and the job's variables to $HELPER_VERSION_OUT, prints
// $HELPER_VERSION (else a version), and exits with $HELPER_VERSION_EXIT.
func version() int {
	if out := os.Getenv("HELPER_VERSION_OUT"); out != "" {
		wd, _ := os.Getwd()
		wd, _ = filepath.EvalSymlinks(wd)
		var b strings.Builder
		fmt.Fprintf(&b, "dir=%s\ntmp=%s\n", wd, os.Getenv("TMPDIR"))
		for _, e := range os.Environ() {
			if strings.HasPrefix(e, "SLIPDOCK_JOB_") {
				fmt.Fprintf(&b, "env=%s\n", e)
			}
		}
		_ = os.WriteFile(out, []byte(b.String()), 0o600)
	}
	said := os.Getenv("HELPER_VERSION")
	if said == "" {
		said = "2.1.0 (Claude Code)\nmore"
	}
	fmt.Println(said)
	code, _ := strconv.Atoi(os.Getenv("HELPER_VERSION_EXIT"))
	return code
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
	// round is the server's round when the job was added: only a claim
	// sent in that round or later takes it (see server.round).
	round int64
}

type finished struct {
	exit           int
	status, merged string
	body           string
	query          url.Values
}

// server is a Slipdock server's runner protocol.
type server struct {
	t  *testing.T
	ts *httptest.Server

	mu          sync.Mutex
	jobs        []fakeJob
	claims      map[int64]int
	claimHeader map[int64]http.Header
	// taker is the X-Test-Round of the claim that took each job: a late
	// claim can overwrite claimHeader, never this.
	taker      map[int64]string
	refuse     map[int64]int // runner → status for its claims
	cancel     map[int64]bool
	lost       map[int64]bool
	beats      map[int64][]string
	finishes   map[int64]finished
	transcript map[int64][]string
	txCap      int
	config     string
	// skills is what /api/skills.tar.gz answers (404 when nil);
	// skillsKey, the Authorization its last fetch sent.
	skills     []byte
	skillsCode int
	skillsGets int
	skillsKey  string
	// skillsSigner signs skills for /api/skills.tar.gz.sig (the rig's
	// release key), unless skillsSig says what it answers instead or
	// skillsUnsigned makes it a 404 (as it is when skills is nil);
	// skillsSigCode fails its fetch, and skillsSigGets counts them.
	skillsSigner   ed25519.PrivateKey
	skillsSig      []byte
	skillsUnsigned bool
	skillsSigCode  int
	skillsSigGets  int
	// cli and cliSums are what /cli/slipdock.escript and /cli/SHA256SUMS
	// answer (404 when nil); cliCode fails the escript's fetch; cliGets
	// counts the escript's fetches and cliKeys the Authorization each of
	// the two sent.
	cli      []byte
	cliSums  []byte
	cliCode  int
	cliGets  int
	sumsGets int
	cliKeys  []string
	// cliSig is what /cli/slipdock.escript.sig answers (404 when nil);
	// cliSigCode fails its fetch; sigGets counts its fetches.
	cliSig     []byte
	cliSigCode int
	sigGets    int
	// round moves on each time a rig's worker has stopped (rig.run), and
	// the rig's client sends the round it is in with each claim
	// (X-Test-Round). A stopped worker's last claim is cancelled on its
	// side, but the server can still read it after the next job has been
	// added, under load (#2689): from an earlier round, it takes nothing,
	// else that job would answer a closed connection and never run.
	round atomic.Int64
}

func newServer(t *testing.T) *server {
	s := &server{t: t, claims: map[int64]int{}, claimHeader: map[int64]http.Header{}, taker: map[int64]string{}, refuse: map[int64]int{},
		cancel: map[int64]bool{}, lost: map[int64]bool{}, beats: map[int64][]string{},
		finishes: map[int64]finished{}, transcript: map[int64][]string{}}
	s.ts = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.ts.Close)
	return s
}

func (s *server) add(j fakeJob) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j.round = s.round.Load()
	s.jobs = append(s.jobs, j)
}

// roundTag is a transport that says which of the server's rounds a
// request was sent in.
type roundTag struct{ s *server }

func (t roundTag) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.Header.Set("X-Test-Round", strconv.FormatInt(t.s.round.Load(), 10))
	return http.DefaultTransport.RoundTrip(req)
}

// takenBy is whether a claim with these headers may take j: one with no
// round (a client other than a rig's) takes any.
func (j fakeJob) takenBy(h http.Header) bool {
	round, err := strconv.ParseInt(h.Get("X-Test-Round"), 10, 64)
	return err != nil || round >= j.round
}

func (s *server) handle(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if r.URL.Path == "/cli/slipdock.escript" || r.URL.Path == "/cli/SHA256SUMS" || r.URL.Path == "/cli/slipdock.escript.sig" {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.cliKeys = append(s.cliKeys, r.Header.Get("Authorization"))
		body, code := s.cliSums, 0
		switch r.URL.Path {
		case "/cli/slipdock.escript":
			s.cliGets++
			body, code = s.cli, s.cliCode
		case "/cli/slipdock.escript.sig":
			s.sigGets++
			body, code = s.cliSig, s.cliSigCode
		default:
			s.sumsGets++
		}
		switch {
		case code != 0:
			w.WriteHeader(code)
		case body == nil:
			w.WriteHeader(404)
		default:
			_, _ = w.Write(body)
		}
		return
	}
	if r.URL.Path == "/api/skills.tar.gz.sig" {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.skillsSigGets++
		switch {
		case s.skillsSigCode != 0:
			w.WriteHeader(s.skillsSigCode)
		case s.skillsSig != nil:
			_, _ = w.Write(s.skillsSig)
		case s.skillsUnsigned || s.skills == nil || s.skillsSigner == nil:
			w.WriteHeader(404)
		default:
			_, _ = w.Write(release.SignIn(release.SkillsNamespace, s.skillsSigner, s.skills))
		}
		return
	}
	if r.URL.Path == "/api/skills.tar.gz" {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.skillsGets++
		s.skillsKey = r.Header.Get("Authorization")
		switch {
		case s.skillsCode != 0:
			w.WriteHeader(s.skillsCode)
		case s.skills == nil:
			w.WriteHeader(404)
		default:
			_, _ = w.Write(s.skills)
		}
		return
	}
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
			if j.runner != rid || !j.takenBy(r.Header) {
				continue
			}
			s.jobs = append(s.jobs[:i], s.jobs[i+1:]...)
			s.taker[j.id] = r.Header.Get("X-Test-Round")
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
		s.finishes[id] = finished{exit, r.URL.Query().Get("status"), r.URL.Query().Get("merged"), string(body), r.URL.Query()}
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

// takerRound is the round the claim that took job said it was sent in.
func (s *server) takerRound(job int64) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.taker[job]
}

// header is the last claim's headers from runner id. A claim still in
// flight when the worker stops can land after the job's finish, so it is
// read under the lock.
func (s *server) header(id int64) http.Header {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claimHeader[id]
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
	// releaseKey signs what the fake server serves; the worker checks
	// against its public half.
	releaseKey ed25519.PrivateKey
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
		Client:  &Client{Server: srv.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{Transport: roundTag{srv}}},
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
		Launcher: os.Args[0],
		// A test's agent exits at once, before any tool call: the quick
		// exit read (#2920) is off unless the test turns it on.
		QuickExit: -1,
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r.releaseKey = priv
	srv.skillsSigner = priv
	r.w.ReleaseKey = func() (ed25519.PublicKey, error) { return pub, nil }
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
	err := <-stopped
	r.srv.round.Add(1)
	if err != nil {
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

// The rig's worker says which round each claim was sent in: without that
// its claims carry no round and take any job, a stopped worker's late one
// too (#2689).
func TestARigWorkersClaimsCarryTheRoundTheyWereSentIn(t *testing.T) {
	r := newRig(t, Config{})
	for i, want := range []string{"0", "1"} {
		id := int64(411 + i)
		if f := r.runJob(fakeJob{id: id, kind: "claude", card: 7, prompt: "x"}); f.exit != 0 {
			t.Fatalf("job %d: %+v", id, f)
		}
		if got := r.srv.takerRound(id); got != want {
			t.Fatalf("the claim that took job %d said round %q, want %q", id, got, want)
		}
	}
}

// A stopped worker's last claim, read by the server only after the next job
// was added (as under load on CI, #2689), takes nothing: the next run gets
// the job. A claim from a client that sends no round takes any job.
func TestALateClaimFromAStoppedWorkerLeavesTheNextJob(t *testing.T) {
	r := newRig(t, Config{})
	if f := r.runJob(fakeJob{id: 401, kind: "claude", card: 7, prompt: "x"}); f.exit != 0 {
		t.Fatalf("the first job: %+v", f)
	}
	r.srv.add(fakeJob{runner: r.w.Runner.ID, id: 402, kind: "claude", card: 7, prompt: "x"})
	claim := func(round string) int {
		req, err := http.NewRequest(http.MethodPost, r.srv.ts.URL+"/api/runner/claim?wait=0", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer sdm_test_key")
		req.Header.Set("X-Runner-Id", strconv.FormatInt(r.w.Runner.ID, 10))
		if round != "" {
			req.Header.Set("X-Test-Round", round)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}
	if code := claim("0"); code != 204 {
		t.Fatalf("a claim sent in the first job's round got %d, want 204 (it took the next job)", code)
	}
	r.run(func() bool { _, ok := r.srv.finish(402); return ok })
	if f, _ := r.srv.finish(402); f.exit != 0 {
		t.Fatalf("the next job: %+v", f)
	}

	r.srv.add(fakeJob{runner: r.w.Runner.ID, id: 403, kind: "claude", card: 7, prompt: "x"})
	if code := claim(""); code != 200 {
		t.Fatalf("a claim with no round got %d, want 200", code)
	}
}
