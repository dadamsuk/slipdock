package runner

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// claims is how many times runner id has claimed.
func (s *server) claimsOf(id int64) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claims[id]
}

func (s *server) kindsOf(id int64) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claimHeader[id].Get("X-Runner-Kinds")
}

// poolWithTree is a pool running the rig's runner, whose job (#130) is a
// process tree that runs until it is stopped, started and ticking.
func poolWithTree(t *testing.T) (*rig, *Pool, string) {
	t.Helper()
	r, tick := treeRig(t, Config{})
	r.srv.add(fakeJob{runner: 11, id: 130, kind: "claude", card: 7, prompt: "x"})
	ctx, cancel := context.WithCancel(context.Background())
	p := NewPool(ctx, r.logged.logf)
	t.Cleanup(func() { cancel(); p.Wait() })
	p.Apply([]*Worker{r.w})
	waitFor(t, "the job's child to tick", func() bool { _, err := os.Stat(tick); return err == nil })
	return r, p, tick
}

func (r *rig) cancelJob(id int64) {
	r.srv.mu.Lock()
	r.srv.cancel[id] = true
	r.srv.mu.Unlock()
}

func TestARemovedRunnerFinishesItsJobThenStops(t *testing.T) {
	r, p, tick := poolWithTree(t)
	claimed := r.srv.claimsOf(11)

	p.Apply(nil)
	if !ticking(t, tick) {
		t.Fatal("the job was cut short by the runner's removal")
	}
	if _, ok := r.srv.finish(130); ok {
		t.Fatal("the job finished before it ended")
	}
	// The job ends (here, cancelled from the board): it is reported, and the
	// runner claims nothing more.
	r.cancelJob(130)
	waitFor(t, "the job's finish", func() bool { _, ok := r.srv.finish(130); return ok })
	time.Sleep(100 * time.Millisecond)
	if n := r.srv.claimsOf(11); n != claimed {
		t.Fatalf("claims went from %d to %d after the runner was removed", claimed, n)
	}
	if !strings.Contains(r.logged.String(), "runner builder (#11) takes no more jobs") {
		t.Fatalf("log:\n%s", r.logged)
	}
}

func TestAChangedRunnerStartsAgainOnceItsJobHasFinished(t *testing.T) {
	r, p, tick := poolWithTree(t)
	claimed := r.srv.claimsOf(11)
	if !strings.HasPrefix(r.srv.kindsOf(11), "claude,") {
		t.Fatalf("kinds %q", r.srv.kindsOf(11))
	}

	changed := *r.w
	changed.Runner.Config.Agent = "codex"
	changed.Runner.ConfigVersion = 2
	p.Apply([]*Worker{&changed})
	if !ticking(t, tick) {
		t.Fatal("the job was cut short by the change")
	}
	if n := r.srv.claimsOf(11); n != claimed {
		t.Fatalf("the new config claimed (%d → %d) while the old one's job ran", claimed, n)
	}
	r.cancelJob(130)
	waitFor(t, "a claim with the new config", func() bool {
		return r.srv.claimsOf(11) > claimed && strings.HasPrefix(r.srv.kindsOf(11), "codex,")
	})
	if !strings.Contains(r.logged.String(), "runner builder (#11) changed: it starts again") {
		t.Fatalf("log:\n%s", r.logged)
	}
}

func TestApplyLeavesAnUnchangedRunnerAlone(t *testing.T) {
	r, p, tick := poolWithTree(t)
	same := *r.w
	same.Runner.ConfigVersion = 9 // a new version with nothing changed
	p.Apply([]*Worker{&same})
	if strings.Contains(r.logged.String(), "changed: it starts again") {
		t.Fatalf("an unchanged runner was restarted:\n%s", r.logged)
	}
	// Sharing its directory with another runner now is a change: a
	// worktree per job is on by default.
	shared := same
	shared.SharedDir = true
	p.Apply([]*Worker{&shared})
	if !strings.Contains(r.logged.String(), "changed: it starts again") {
		t.Fatalf("a runner now sharing its directory wasn't restarted:\n%s", r.logged)
	}
	if !ticking(t, tick) {
		t.Fatal("the job was cut short")
	}
}

func TestAPoolStartsANewRunnerAndStopsOnRevocation(t *testing.T) {
	srv := newServer(t)
	logs := &logBuf{}
	worker := func(id int64) *Worker {
		return &Worker{Runner: Runner{ID: id, Name: "r", BoardID: 3, Config: Config{Agent: "claude"}},
			Client: &Client{Server: srv.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{}}, Logf: logs.logf,
			LookPath: func(string) (string, error) { return "", errors.New("no") }, Getenv: func(string) string { return "" }}
	}
	p := NewPool(context.Background(), logs.logf)
	p.Apply([]*Worker{worker(1)})
	waitFor(t, "runner 1 to claim", func() bool { return srv.claimsOf(1) > 0 })
	p.Apply([]*Worker{worker(1), worker(2)})
	waitFor(t, "runner 2, added at runtime, to claim", func() bool { return srv.claimsOf(2) > 0 })

	srv.mu.Lock()
	srv.refuse[2] = 401
	srv.mu.Unlock()
	if err := p.Wait(); !errors.Is(err, ErrRevoked) {
		t.Fatalf("Wait = %v, want ErrRevoked", err)
	}
	if p.Context().Err() == nil {
		t.Fatal("a revoked machine ends the pool's context")
	}
}

func TestAReplacedRunnerLeftOutAgainNeverStarts(t *testing.T) {
	r, p, _ := poolWithTree(t)
	claimed := r.srv.claimsOf(11)
	changed := *r.w
	changed.Runner.Config.Agent = "codex"
	p.Apply([]*Worker{&changed})
	p.Apply(nil)
	r.cancelJob(130)
	waitFor(t, "the job's finish", func() bool { _, ok := r.srv.finish(130); return ok })
	time.Sleep(100 * time.Millisecond)
	if n := r.srv.claimsOf(11); n != claimed {
		t.Fatalf("the replacement claimed (%d → %d) after being left out", claimed, n)
	}
}

func TestAClaimToldToStop(t *testing.T) {
	// A long claim waiting on the server is dropped when the stop comes.
	waiting := make(chan struct{})
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(waiting)
		<-r.Context().Done()
	}))
	defer ts.Close()
	stop := make(chan struct{})
	c := &Client{Server: ts.URL, Key: "k", HTTP: &http.Client{}, Stop: stop}
	got := make(chan error, 1)
	go func() { _, _, err := c.Claim(context.Background(), 1, nil, 25); got <- err }()
	<-waiting
	close(stop)
	select {
	case err := <-got:
		if !errors.Is(err, ErrStopped) {
			t.Fatalf("err = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the waiting claim wasn't dropped")
	}
	// Once stopped, no claim is made at all.
	if _, _, err := c.Claim(context.Background(), 1, nil, 25); !errors.Is(err, ErrStopped) || ErrStopped.Error() != "this runner was told to stop" {
		t.Fatalf("err = %v", err)
	}
}

func TestReportAndTheListing(t *testing.T) {
	var (
		mu     sync.Mutex
		status = 200
		got    map[string]any
		ctype  string
		path   string
	)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/api/machine/config" {
			io.WriteString(w, `{"version":5,"runners":[{"id":3,"name":"b","board_id":2,"pool":"p","config_version":4,"paused":true,"config":{"agent":"claude"}}]}`)
			return
		}
		path, ctype = r.URL.Path, r.Header.Get("Content-Type")
		got = nil
		json.NewDecoder(r.Body).Decode(&got)
		w.WriteHeader(status)
	}))
	defer ts.Close()
	c := &Client{Server: ts.URL, Key: "k", HTTP: &http.Client{}}

	l, err := c.FetchConfig(context.Background(), -1, 0)
	if err != nil || l.Version != 5 || len(l.Runners) != 1 || !l.Runners[0].Paused || l.Runners[0].Config.Agent != "claude" || l.Runners[0].ConfigVersion != 4 {
		t.Fatalf("listing %+v, %v", l, err)
	}

	if err := c.Report(context.Background(), 3, 4, "rejected", "too wide"); err != nil {
		t.Fatal(err)
	}
	if path != "/api/machine/runners/3/report" || ctype != "application/json" ||
		got["version"] != float64(4) || got["outcome"] != "rejected" || got["reason"] != "too wide" {
		t.Fatalf("sent %s %s %v", path, ctype, got)
	}
	for code, ok := range map[int]bool{409: true, 404: true, 500: false, 401: false} {
		mu.Lock()
		status = code
		mu.Unlock()
		err := c.Report(context.Background(), 3, 4, "accepted", "")
		if (err == nil) != ok {
			t.Errorf("HTTP %d: err = %v", code, err)
		}
		if code == 401 && !IsRevoked(err) {
			t.Errorf("a 401 is the machine revoked: %v", err)
		}
	}
}
