package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
)

// ceilingServer answers PUT /api/machine/ceiling with each status in
// answers in turn (then 200), keeping what was sent.
type ceilingServer struct {
	mu      sync.Mutex
	answers []int
	tries   int
	sent    []map[string]any
}

func (s *ceilingServer) handle(w http.ResponseWriter, r *http.Request) {
	var body map[string]map[string]any
	json.NewDecoder(r.Body).Decode(&body)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tries++
	status := http.StatusOK
	if len(s.answers) > 0 {
		status, s.answers = s.answers[0], s.answers[1:]
	}
	if r.Method != http.MethodPut {
		status = http.StatusMethodNotAllowed
	}
	if status == http.StatusOK {
		s.sent = append(s.sent, body["ceiling"])
	}
	w.WriteHeader(status)
	fmt.Fprint(w, `{"error":"no"}`)
}

func (s *ceilingServer) counts() (tries, sent int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tries, len(s.sent)
}

func testCeiling() machine.Ceiling {
	return machine.Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 60, Boards: []int64{3}, Executors: []string{"me", "confined"}}
}

func TestReportCeilingTriesAgainUntilSentBackingOff(t *testing.T) {
	oldRetry, oldMax := configRetry, ceilingRetryMax
	configRetry, ceilingRetryMax = time.Second, 3*time.Second
	t.Cleanup(func() { configRetry, ceilingRetryMax = oldRetry, oldMax })
	srv := &ceilingServer{answers: []int{503, 502, 500, 404}}
	ts := httptest.NewServer(http.HandlerFunc(srv.handle))
	defer ts.Close()
	client := &runner.Client{Server: ts.URL, Key: "sdm_key", HTTP: ts.Client()}
	var waits []time.Duration
	var logs []string
	pause := func(ctx context.Context, d time.Duration) error { waits = append(waits, d); return nil }
	logf := func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) }

	reportCeiling(context.Background(), client, testCeiling(), pause, logf)

	if tries, sent := srv.counts(); tries != 5 || sent != 1 {
		t.Fatalf("tries %d, sent %d: want 5 tries and the ceiling sent once", tries, sent)
	}
	if fmt.Sprint(waits) != "[1s 2s 3s 3s]" {
		t.Errorf("waited %v between tries, want doubling from configRetry up to ceilingRetryMax", waits)
	}
	if ex, _ := srv.sent[0]["executors"].([]any); len(ex) != 2 || ex[1] != "confined" {
		t.Errorf("sent executors %v, want the ceiling's", srv.sent[0]["executors"])
	}
	all := strings.Join(logs, "\n")
	for _, want := range []string{"can't report the ceiling, trying again in 1s: HTTP 503", "reported the ceiling (executors me, confined)"} {
		if !strings.Contains(all, want) {
			t.Errorf("the log doesn't say %q:\n%s", want, all)
		}
	}
}

func TestReportCeilingStopsOnARefusal(t *testing.T) {
	for _, status := range []int{422, 401} {
		srv := &ceilingServer{answers: []int{status}}
		ts := httptest.NewServer(http.HandlerFunc(srv.handle))
		client := &runner.Client{Server: ts.URL, Key: "sdm_key", HTTP: ts.Client()}
		paused := 0
		var logs []string
		reportCeiling(context.Background(), client, testCeiling(),
			func(context.Context, time.Duration) error { paused++; return nil },
			func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) })
		ts.Close()
		if tries, _ := srv.counts(); tries != 1 || paused != 0 {
			t.Errorf("HTTP %d: %d tries, %d waits; a refusal is final", status, tries, paused)
		}
		if !strings.Contains(strings.Join(logs, "\n"), "the server refused the ceiling") {
			t.Errorf("HTTP %d: the log doesn't say it was refused: %v", status, logs)
		}
	}
}

func TestReportCeilingEndsWithItsContext(t *testing.T) {
	srv := &ceilingServer{answers: []int{503, 503, 503}}
	ts := httptest.NewServer(http.HandlerFunc(srv.handle))
	defer ts.Close()
	client := &runner.Client{Server: ts.URL, Key: "sdm_key", HTTP: ts.Client()}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		reportCeiling(ctx, client, testCeiling(), func(ctx context.Context, d time.Duration) error {
			cancel()
			return ctx.Err()
		}, func(string, ...any) {})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("reportCeiling went on after its context ended")
	}
	if tries, sent := srv.counts(); tries != 1 || sent != 0 {
		t.Fatalf("tries %d, sent %d after the context ended", tries, sent)
	}
}

// TestRunReportsTheCeilingAtTheStart runs the daemon against a server whose
// ceiling endpoint fails at first: run reports the machine's ceiling, with
// its executors, once it can.
func TestRunReportsTheCeilingAtTheStart(t *testing.T) {
	cfg := &configServer{}
	w, start := liveWorld(t, cfg)
	st, key, _ := machine.Load(w.dir)
	upstream, _ := url.Parse(st.Server)
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	ceil := &ceilingServer{answers: []int{503}}
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
	// The server records the ceiling before the daemon has its answer and
	// logs it, so the test waits for the log line too before it stops the
	// daemon (#2650), reading the log through a lock as the daemon writes it.
	log := &lockedBuffer{}
	w.env.Stderr = log
	stop := start()
	waitUntil(t, "the ceiling to be reported", func() bool { _, sent := ceil.counts(); return sent == 1 })
	waitUntil(t, "the ceiling's report to be logged", func() bool {
		return strings.Contains(log.String(), "reported the ceiling (executors ")
	})
	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, log)
	}
	want, _ := machine.LoadCeiling(w.dir)
	got := ceil.sent[0]
	if roots, _ := got["roots"].([]any); len(roots) != 1 || roots[0] != want.Roots[0] {
		t.Errorf("sent roots %v, want the machine's %v", got["roots"], want.Roots)
	}
	if ex, _ := got["executors"].([]any); len(ex) != len(want.Executors) || ex[0] != want.Executors[0] {
		t.Errorf("sent executors %v, want the machine's %v", got["executors"], want.Executors)
	}
	if tries, _ := ceil.counts(); tries != 2 {
		t.Errorf("%d tries: want one failed and one sent", tries)
	}
	for _, want := range []string{"can't report the ceiling, trying again", "reported the ceiling (executors "} {
		if !strings.Contains(log.String(), want) {
			t.Errorf("the log doesn't say %q:\n%s", want, log)
		}
	}
}

// lockedBuffer is a log a test can read while the daemon writes to it.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// TestRunRunnersWaitsForTheCeilingsReport holds the ceiling's report in the
// middle of logging while the run is stopped: runRunners doesn't return
// until the report has ended, so nothing it logs lands after the run has
// finished (#2644; a test reading the log then raced the report's write).
func TestRunRunnersWaitsForTheCeilingsReport(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		rw.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(ts.Close)
	w := newWorld(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	logf := func(f string, a ...any) {
		if strings.HasPrefix(f, "can't report the ceiling") {
			once.Do(func() { close(entered) })
			<-release
		}
	}
	pause := func(ctx context.Context, _ time.Duration) error { <-ctx.Done(); return ctx.Err() }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		runRunners(ctx, t.TempDir(), machine.State{Server: ts.URL}, "sdm_key", testCeiling(), machine.Local{},
			w.env, pause, logf, make(chan struct{}), make(chan struct{}))
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the ceiling's report never logged its failure")
	}
	cancel()
	select {
	case <-returned:
		close(release)
		t.Fatal("runRunners returned while the ceiling's report was still logging")
	case <-time.After(200 * time.Millisecond):
	}
	close(release)
	select {
	case <-returned:
	case <-time.After(5 * time.Second):
		t.Fatal("runRunners didn't return once the ceiling's report had ended")
	}
}
