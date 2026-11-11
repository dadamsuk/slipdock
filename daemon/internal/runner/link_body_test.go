package runner

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/link"
)

// linkClient is a Client claiming from s over a link without pings: only
// a request's own deadline or its cancelling says anything about the
// connection.
func linkClient(t *testing.T, s *holeServer) (*Client, *link.Link) {
	t.Helper()
	l := link.New(link.Options{PingAfter: -1, TLS: s.ts.Client().Transport.(*http.Transport).TLSClientConfig})
	return &Client{Server: s.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{Transport: l}, Conns: l}, l
}

// hold holds a claim until the client gives it up or the test ends.
func hold(c *holeConn, r *http.Request) {
	select {
	case <-r.Context().Done():
	case <-c.quit:
	}
}

func TestAConnectionThatDiesMidBodyIsDroppedAndTheRetryIsOnANewOne(t *testing.T) {
	// The first claim's headers arrive, then its connection goes silent
	// before the body: the claim fails reading it, at its deadline.
	old := PollSlack
	PollSlack = 300 * time.Millisecond
	t.Cleanup(func() { PollSlack = old })
	s := newHoleServer(t, func(n int, c *holeConn, w http.ResponseWriter, r *http.Request) {
		if n == 1 {
			w.Header().Set("X-Job-Id", "41")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			c.silent.Store(true)
			hold(c, r)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	client, l := linkClient(t, s)

	if _, _, err := client.Claim(context.Background(), 11, nil, 1); err == nil {
		t.Fatal("a claim whose body never came succeeded")
	}
	if l.Gen() != 1 {
		t.Fatalf("the link's generation is %d after a body read failed, want 1: the connection wasn't dropped", l.Gen())
	}
	first := s.seen()[0]
	select {
	case <-s.ln.conn(first.addr).closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the connection that died mid-body is still open at the client")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := client.Claim(ctx, 11, nil, 1); err != nil {
		t.Fatalf("the retry failed: %v", err)
	}
	seen := s.seen()
	if len(seen) != 2 || seen[1].addr == first.addr {
		t.Fatalf("the retry wasn't read on a new connection: %+v", seen)
	}
	if l.Dials() != 2 {
		t.Fatalf("the link dialled %d connections, want 2", l.Dials())
	}
}

func TestACancelledClaimLeavesTheConnection(t *testing.T) {
	// A claim cancelled, by the daemon stopping (its context) or the
	// runner told to stop (Client.Stop), says nothing about the
	// connection: it stays, and the next claim goes on it.
	s := newHoleServer(t, func(n int, c *holeConn, w http.ResponseWriter, r *http.Request) {
		if n <= 2 {
			hold(c, r)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	client, l := linkClient(t, s)

	// The daemon stopping: the claim's context is cancelled.
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		s.waitFor(t, 1, 10*time.Second)
		cancel()
	}()
	if _, _, err := client.Claim(ctx, 11, nil, 25); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled claim: %v, want context.Canceled", err)
	}
	if l.Gen() != 0 || l.Dials() != 1 {
		t.Fatalf("a cancelled claim dropped the link: generation %d, %d dials; want 0 and 1", l.Gen(), l.Dials())
	}

	// The runner told to stop.
	stop := make(chan struct{})
	client.Stop = stop
	go func() {
		s.waitFor(t, 2, 10*time.Second)
		close(stop)
	}()
	if _, _, err := client.Claim(context.Background(), 11, nil, 25); !errors.Is(err, ErrStopped) {
		t.Fatalf("a stopped claim: %v, want ErrStopped", err)
	}
	if l.Gen() != 0 || l.Dials() != 1 {
		t.Fatalf("a stopped claim dropped the link: generation %d, %d dials; want 0 and 1", l.Gen(), l.Dials())
	}

	client.Stop = nil
	if _, _, err := client.Claim(context.Background(), 11, nil, 1); err != nil {
		t.Fatal(err)
	}
	seen := s.seen()
	if len(seen) != 3 || seen[2].addr != seen[0].addr || seen[1].addr != seen[0].addr {
		t.Fatalf("the claims after a cancel weren't on the one connection: %+v", seen)
	}
}
