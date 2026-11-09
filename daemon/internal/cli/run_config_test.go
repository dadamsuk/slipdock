package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
)

// configServer is a Slipdock server whose machine config changes while
// the daemon runs: its long-poll answers a newer version at once, else
// waits a little and says no change.
type configServer struct {
	mu      sync.Mutex
	version int64
	runners []string // each runner's JSON
	down    bool     // the config endpoint fails
	// answer, when set, is a listing sent at once on every ask, whatever
	// version was asked for: a server that doesn't honour the long-poll.
	answer  string
	asks    int
	claims  map[string]int
	reports []string
}

func (s *configServer) set(runners ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.version++
	s.runners = runners
}

func (s *configServer) claimsOf(id string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claims[id]
}

func (s *configServer) reported() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.reports, "\n")
}

func (s *configServer) start(t *testing.T) *httptest.Server {
	s.claims = map[string]int{}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sdm_key" {
			w.WriteHeader(401)
			return
		}
		switch {
		case r.URL.Path == "/api/machine":
			w.Write([]byte(`{"machine":{"id":7,"name":"box","boards":[3],"state":"enrolled"}}`))
		case r.URL.Path == "/api/machine/config":
			s.mu.Lock()
			s.asks++
			answer := s.answer
			s.mu.Unlock()
			if answer != "" {
				w.Write([]byte(answer))
				return
			}
			since, _ := strconv.ParseInt(r.URL.Query().Get("version"), 10, 64)
			deadline := time.Now().Add(100 * time.Millisecond)
			for {
				s.mu.Lock()
				down, v, rs := s.down, s.version, s.runners
				s.mu.Unlock()
				switch {
				case down:
					w.WriteHeader(503)
					return
				case v > since:
					fmt.Fprintf(w, `{"version":%d,"runners":[%s]}`, v, strings.Join(rs, ","))
					return
				case time.Now().After(deadline):
					w.WriteHeader(204)
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
		case r.URL.Path == "/api/runner/claim":
			s.mu.Lock()
			s.claims[r.Header.Get("X-Runner-Id")]++
			s.mu.Unlock()
			time.Sleep(20 * time.Millisecond)
			w.WriteHeader(204)
		case strings.HasSuffix(r.URL.Path, "/report"):
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			s.mu.Lock()
			s.reports = append(s.reports, fmt.Sprintf("%s v%v %v", strings.Split(r.URL.Path, "/")[4], body["version"], body["outcome"]))
			s.mu.Unlock()
			w.Write([]byte(`{}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(ts.Close)
	return ts
}

// runnerJSON is a runner in the machine's config.
func runnerJSON(id, version int, dir, mode string, paused bool) string {
	return fmt.Sprintf(`{"id":%d,"name":"r%d","board_id":3,"pool":"default","config_version":%d,"paused":%v,
		"config":{"agent":"claude","directory":%s,"permission_mode":%q,"timeout_minutes":30,"executor":"me","worktree":"off"}}`,
		id, id, version, paused, jsonString(dir), mode)
}

// liveWorld is an enrolled machine pointed at srv, whose run is stopped by
// the test, not by its sleeps.
func liveWorld(t *testing.T, srv *configServer) (*world, func() (stop func() int)) {
	old := configRetry
	configRetry = 20 * time.Millisecond
	t.Cleanup(func() { configRetry = old })
	w, _ := enrolled(t)
	ts := srv.start(t)
	st, key, _ := machine.Load(w.dir)
	st.Server = ts.URL
	if err := machine.Save(w.dir, st, key); err != nil {
		t.Fatal(err)
	}
	w.env.Sleep = func(ctx context.Context, d time.Duration) error {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
			return nil
		}
	}
	return w, func() func() int {
		ctx, cancel := context.WithCancel(context.Background())
		w.env.Context = func() (context.Context, context.CancelFunc) { return ctx, cancel }
		code := make(chan int, 1)
		go func() { code <- Main([]string{"run"}, w.env) }()
		return func() int { cancel(); return <-code }
	}
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRunFollowsTheConfigAsItChanges(t *testing.T) {
	srv := &configServer{}
	w, start := liveWorld(t, srv)
	repo := filepath.Join(w.home, "repo")
	srv.set(runnerJSON(21, 1, repo, "default", false))
	stop := start()

	waitUntil(t, "runner 21 to claim and be reported accepted", func() bool {
		return srv.claimsOf("21") > 0 && strings.Contains(srv.reported(), "21 v1 accepted")
	})

	// 21 widened past the ceiling (rejected, and it runs on as it was), 23
	// added: no restart.
	srv.set(runnerJSON(21, 2, repo, "bypassPermissions", false), runnerJSON(23, 1, repo, "acceptEdits", false))
	waitUntil(t, "runner 23 to claim, and both reported", func() bool {
		return srv.claimsOf("23") > 0 && strings.Contains(srv.reported(), "21 v2 rejected") && strings.Contains(srv.reported(), "23 v1 accepted")
	})
	n := srv.claimsOf("21")
	waitUntil(t, "runner 21 to keep claiming on its last accepted config", func() bool { return srv.claimsOf("21") > n+2 })

	// 21 removed, 23 paused: neither takes another job.
	srv.set(runnerJSON(23, 2, repo, "acceptEdits", true))
	waitUntil(t, "the change to be taken", func() bool { return strings.Contains(srv.reported(), "23 v2 accepted") })
	time.Sleep(100 * time.Millisecond)
	a, b := srv.claimsOf("21"), srv.claimsOf("23")
	time.Sleep(200 * time.Millisecond)
	if srv.claimsOf("21") != a || srv.claimsOf("23") != b {
		t.Fatalf("claims went on after a removal and a pause: 21 %d → %d, 23 %d → %d", a, srv.claimsOf("21"), b, srv.claimsOf("23"))
	}

	if code := stop(); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	changes, _ := os.ReadFile(filepath.Join(w.dir, machineconfig.ChangeLog))
	for _, want := range []string{
		"runner r21 (#21) v1 added and accepted",
		`runner r21 (#21) v2 rejected, it keeps v1: permission mode "bypassPermissions" is above acceptEdits`,
		"runner r23 (#23) v1 added and accepted",
		"runner r21 (#21) removed",
		"runner r23 (#23) v2 changed and accepted: paused false → true",
	} {
		if !strings.Contains(string(changes), want) {
			t.Errorf("the change log doesn't say %q:\n%s", want, changes)
		}
	}
	for _, want := range []string{"config version 1: 1 of 1 runners running", "config version 2: 2 of 2 runners running", "config version 3: 0 of 1 runners running"} {
		if !strings.Contains(w.errOut.String(), want) {
			t.Errorf("the log doesn't say %q:\n%s", want, w.errOut)
		}
	}
}

func TestRunStartsFromTheCacheWhenTheServerIsDown(t *testing.T) {
	srv := &configServer{}
	w, start := liveWorld(t, srv)
	repo := filepath.Join(w.home, "repo")
	srv.set(runnerJSON(21, 4, repo, "default", false))
	stop := start()
	waitUntil(t, "the config to be taken", func() bool { return strings.Contains(srv.reported(), "21 v4 accepted") })
	stop()

	// The server's config can't be read: the daemon runs what it accepted.
	srv.mu.Lock()
	srv.down, srv.claims = true, map[string]int{}
	srv.mu.Unlock()
	stop = start()
	waitUntil(t, "runner 21 to claim from the cache", func() bool { return srv.claimsOf("21") > 0 })
	if code := stop(); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(w.errOut.String(), "the server can't be reached, so starting from the cached config (version 1)") {
		t.Fatalf("log:\n%s", w.errOut)
	}

	// No cache and no server: nothing runs until the server answers.
	os.Remove(filepath.Join(w.dir, machineconfig.CacheFile))
	srv.mu.Lock()
	srv.claims = map[string]int{}
	srv.mu.Unlock()
	stop = start()
	time.Sleep(200 * time.Millisecond)
	if srv.claimsOf("21") != 0 {
		t.Fatal("a runner ran with no config")
	}
	srv.mu.Lock()
	srv.down = false
	srv.mu.Unlock()
	waitUntil(t, "runner 21 to claim once the server answers", func() bool { return srv.claimsOf("21") > 0 })
	stop()
}

func TestRunSaysWhenTheCacheIsBroken(t *testing.T) {
	srv := &configServer{}
	w, start := liveWorld(t, srv)
	os.WriteFile(filepath.Join(w.dir, machineconfig.CacheFile), []byte("not json"), 0o600)
	srv.set(runnerJSON(21, 1, filepath.Join(w.home, "repo"), "default", false))
	stop := start()
	waitUntil(t, "runner 21 to claim", func() bool { return srv.claimsOf("21") > 0 })
	stop()
	if !strings.Contains(w.errOut.String(), "can't read the cached config, so waiting for the server's") {
		t.Fatalf("log:\n%s", w.errOut)
	}
}

func (s *configServer) asked() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.asks
}

// A listing at a version no newer than the one taken (the same, or older)
// is not applied, and run waits configRetry before asking again rather
// than asking at once.
func TestRunIgnoresAListingNoNewerThanTheOneTaken(t *testing.T) {
	for name, version := range map[string]int{"the same version": 2, "an older version": 1} {
		t.Run(name, func(t *testing.T) {
			srv := &configServer{}
			w, start := liveWorld(t, srv)
			configRetry = 300 * time.Millisecond
			repo := filepath.Join(w.home, "repo")
			srv.set(runnerJSON(21, 1, repo, "default", false))
			srv.set(runnerJSON(21, 2, repo, "default", false))
			stop := start()
			waitUntil(t, "version 2 to be taken", func() bool { return strings.Contains(srv.reported(), "21 v2 accepted") })

			// Now the server answers at once with a listing at version
			// 2 or 1 that removes 21 and adds 23.
			srv.mu.Lock()
			srv.answer = fmt.Sprintf(`{"version":%d,"runners":[%s]}`, version, runnerJSON(23, 1, repo, "default", false))
			srv.mu.Unlock()
			before := srv.asked()
			time.Sleep(700 * time.Millisecond)
			asks := srv.asked() - before
			n21 := srv.claimsOf("21")
			waitUntil(t, "runner 21 to keep claiming", func() bool { return srv.claimsOf("21") > n21 })
			if code := stop(); code != 0 {
				t.Fatalf("exit %d: %s", code, w.errOut)
			}
			if asks < 1 || asks > 4 {
				t.Fatalf("%d asks in 700ms: run should wait %s between them", asks, configRetry)
			}
			if srv.claimsOf("23") != 0 || strings.Contains(srv.reported(), "23 v1") {
				t.Fatalf("the listing was applied: claims 21 %d, 23 %d; reports %s", srv.claimsOf("21"), srv.claimsOf("23"), srv.reported())
			}
			log := w.errOut.String()
			if strings.Count(log, "config version ") != 1 || !strings.Contains(log, "config version 2: 1 of 1 runners running") {
				t.Fatalf("the listing was applied again:\n%s", log)
			}
			changes, _ := os.ReadFile(filepath.Join(w.dir, machineconfig.ChangeLog))
			if strings.Contains(string(changes), "#23") || strings.Contains(string(changes), "removed") {
				t.Fatalf("the change log took the listing:\n%s", changes)
			}
		})
	}
}
