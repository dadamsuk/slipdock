package cli

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/link"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// The machine's config poll and the ceiling's report over the daemon's
// channel to the server (#2807): a failure waits, and the channel waking
// (the machine woke from sleep) ends the wait at once.
func TestTheConfigPollAsksAgainAtOnceWhenTheMachineWakes(t *testing.T) {
	var mu sync.Mutex
	asks := map[string]int{}
	remotes := map[string]bool{}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		asks[r.URL.Path]++
		if r.URL.Path == "/api/machine/config" {
			remotes[r.RemoteAddr] = true
		}
		mu.Unlock()
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(ts.Close)
	count := func(path string) int {
		mu.Lock()
		defer mu.Unlock()
		return asks[path]
	}
	waitFor := func(path string, n int) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for count(path) < n {
			if time.Now().After(deadline) {
				t.Fatalf("%s asked %d times, want %d", path, count(path), n)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	w, _ := enrolled(t)
	conns := link.New(link.Options{PingAfter: -1})
	// Every pause lasts until the context ends: only a wake moves on.
	pause := func(ctx context.Context, _ time.Duration) error { <-ctx.Done(); return ctx.Err() }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runRunners(ctx, t.TempDir(), machine.State{Server: ts.URL}, "sdm_key", testCeiling(), machine.Local{},
			w.env, conns, pause, func(string, ...any) {}, make(chan struct{}), make(chan struct{}))
	}()
	t.Cleanup(func() { cancel(); <-done })

	waitFor("/api/machine/config", 1)
	waitFor("/api/machine/ceiling", 1)
	time.Sleep(200 * time.Millisecond)
	if n := count("/api/machine/config"); n != 1 {
		t.Fatalf("the config was asked %d times before the wake, want 1", n)
	}
	conns.Wake()
	waitFor("/api/machine/config", 2)
	waitFor("/api/machine/ceiling", 2)
	mu.Lock()
	defer mu.Unlock()
	if len(remotes) != 2 {
		t.Fatalf("the config polls came from %d connections, want 2: a wake drops the old one", len(remotes))
	}
}
