package runner

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// A Client with no link (Conns nil, #2822) over HTTP/1.1: a request that
// fails closes the transport's idle connections, since whatever broke one
// connection to the server has likely broken the others.

// plainServer is an HTTP/1.1 server whose first two claims are answered
// together, so they come on two connections that both end up idle in the
// client's pool. The third is held; later ones are answered at once.
type plainServer struct {
	ts     *httptest.Server
	mu     sync.Mutex
	addrs  []string
	closed map[string]bool
	both   chan struct{}
	quit   chan struct{}
}

func newPlainServer(t *testing.T) *plainServer {
	t.Helper()
	s := &plainServer{closed: map[string]bool{}, both: make(chan struct{}), quit: make(chan struct{})}
	s.ts = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.addrs = append(s.addrs, r.RemoteAddr)
		n := len(s.addrs)
		s.mu.Unlock()
		switch {
		case n == 2:
			close(s.both)
		case n == 3:
			select {
			case <-r.Context().Done():
			case <-s.quit:
			}
			return
		}
		if n <= 2 {
			select {
			case <-s.both:
			case <-s.quit:
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	s.ts.Config.ConnState = func(c net.Conn, st http.ConnState) {
		if st == http.StateClosed {
			s.mu.Lock()
			s.closed[c.RemoteAddr().String()] = true
			s.mu.Unlock()
		}
	}
	s.ts.Start()
	t.Cleanup(s.ts.Close)
	// Before Close, which waits for the held claim.
	t.Cleanup(func() { close(s.quit) })
	return s
}

func (s *plainServer) seen() (addrs []string, closed map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	closed = map[string]bool{}
	for k, v := range s.closed {
		closed[k] = v
	}
	return append([]string(nil), s.addrs...), closed
}

func (s *plainServer) waitFor(t *testing.T, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if addrs, _ := s.seen(); len(addrs) >= n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the server never read claim %d", n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// twoIdle is a Client without a link whose pool holds two idle
// connections to s, and their addresses.
func twoIdle(t *testing.T, s *plainServer) (*Client, [2]string) {
	t.Helper()
	tr := &http.Transport{}
	t.Cleanup(tr.CloseIdleConnections)
	client := &Client{Server: s.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{Transport: tr}}
	errs := make(chan error, 2)
	for range 2 {
		go func() {
			_, _, err := client.Claim(context.Background(), 11, nil, 5)
			errs <- err
		}()
	}
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	addrs, _ := s.seen()
	if len(addrs) != 2 || addrs[0] == addrs[1] {
		t.Fatalf("the two claims at once weren't on two connections: %v", addrs)
	}
	return client, [2]string{addrs[0], addrs[1]}
}

func TestAClaimThatTimesOutWithoutALinkClosesTheIdleConnections(t *testing.T) {
	old := PollSlack
	PollSlack = 300 * time.Millisecond
	t.Cleanup(func() { PollSlack = old })
	s := newPlainServer(t)
	client, idle := twoIdle(t, s)

	if _, _, err := client.Claim(context.Background(), 11, nil, 0); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a claim never answered: %v, want its deadline", err)
	}
	// Both connections from before are closed at the client: the one the
	// claim timed out on, and the one that sat idle beside it.
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, closed := s.seen()
		if closed[idle[0]] && closed[idle[1]] {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("a connection from before the failed claim is still open at the client: %v closed of %v", closed, idle)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, _, err := client.Claim(context.Background(), 11, nil, 1); err != nil {
		t.Fatalf("the retry failed: %v", err)
	}
	addrs, _ := s.seen()
	if retry := addrs[len(addrs)-1]; len(addrs) != 4 || retry == idle[0] || retry == idle[1] {
		t.Fatalf("the retry wasn't read on a new connection: %v", addrs)
	}
}

func TestACancelledClaimWithoutALinkLeavesTheIdleConnections(t *testing.T) {
	// Cancelled (the daemon stopping), not timed out: that says nothing
	// about the server's connections, and the next claim goes on one the
	// pool already had.
	s := newPlainServer(t)
	client, idle := twoIdle(t, s)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		s.waitFor(t, 3)
		cancel()
	}()
	if _, _, err := client.Claim(ctx, 11, nil, 25); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled claim: %v, want context.Canceled", err)
	}
	if _, _, err := client.Claim(context.Background(), 11, nil, 1); err != nil {
		t.Fatal(err)
	}
	addrs, _ := s.seen()
	if next := addrs[len(addrs)-1]; len(addrs) != 4 || (next != idle[0] && next != idle[1]) {
		t.Fatalf("the claim after a cancel wasn't on a connection from before it (%v): %v", idle, addrs)
	}
}
