package cli

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/link"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// checkServer answers the machine's enrolment check (/api/machine) with
// status(n) for the n-th check, and 404 to everything else. It records
// the connection each check came on, and which connections have closed.
type checkServer struct {
	ts     *httptest.Server
	mu     sync.Mutex
	checks []string
	closed map[string]bool
}

func newCheckServer(t *testing.T, status func(n int) int) *checkServer {
	s := &checkServer{closed: map[string]bool{}}
	s.ts = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/machine" {
			http.NotFound(w, r)
			return
		}
		s.mu.Lock()
		s.checks = append(s.checks, r.RemoteAddr)
		n := len(s.checks)
		s.mu.Unlock()
		if code := status(n); code != http.StatusOK {
			w.WriteHeader(code)
			return
		}
		w.Write([]byte(`{"machine":{"id":7,"name":"box","boards":[3],"state":"enrolled"}}`))
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
	return s
}

func (s *checkServer) seen() ([]string, map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	closed := map[string]bool{}
	for k, v := range s.closed {
		closed[k] = v
	}
	return append([]string(nil), s.checks...), closed
}

// enrolledAt is an enrolled machine whose server is s.
func enrolledAt(t *testing.T, s *checkServer) *world {
	w, _ := enrolled(t)
	st, key, err := machine.Load(w.dir)
	if err != nil {
		t.Fatal(err)
	}
	st.Server = s.ts.URL
	if err := machine.Save(w.dir, st, key); err != nil {
		t.Fatal(err)
	}
	return w
}

func TestAFailedEnrolmentCheckIsTriedAgainOnANewConnection(t *testing.T) {
	// The first check fails (#2807): its connection is dropped, so the
	// next check is made on a new one, not the one that just failed.
	s := newCheckServer(t, func(n int) int {
		if n == 1 {
			return http.StatusBadGateway
		}
		return http.StatusOK
	})
	w := enrolledAt(t, s)
	w.stopAfterSleep = 2
	if code := w.main("run"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	checks, closed := s.seen()
	if len(checks) != 2 {
		t.Fatalf("the machine checked %d times, want 2", len(checks))
	}
	if !strings.Contains(w.errOut.String(), "can't reach the server") {
		t.Fatalf("the failed check wasn't logged:\n%s", w.errOut)
	}
	if checks[1] == checks[0] {
		t.Fatalf("the check after a failure went on the connection that failed (%s)", checks[0])
	}
	// The failed connection was closed by the daemon, not left idle in
	// its pool for a later request to pick up.
	deadline := time.Now().Add(2 * time.Second)
	for !closed[checks[0]] {
		if time.Now().After(deadline) {
			t.Fatalf("the connection the check failed on (%s) is still open", checks[0])
		}
		time.Sleep(10 * time.Millisecond)
		_, closed = s.seen()
	}
}

func TestAWakeEndsTheEnrolmentChecksPause(t *testing.T) {
	// The pause between checks lasts until the run stops: only a wake
	// (the machine woke from sleep) brings the next check, at once.
	s := newCheckServer(t, func(int) int { return http.StatusOK })
	w := enrolledAt(t, s)
	var mu sync.Mutex
	var conns *link.Link
	linkMade = func(l *link.Link) { mu.Lock(); conns = l; mu.Unlock() }
	t.Cleanup(func() { linkMade = nil })
	w.env.Sleep = func(ctx context.Context, _ time.Duration) error { <-ctx.Done(); return ctx.Err() }
	ctx, cancel := context.WithCancel(context.Background())
	w.env.Context = func() (context.Context, context.CancelFunc) { return ctx, cancel }
	done := make(chan int)
	go func() { done <- w.main("run") }()
	t.Cleanup(func() { cancel(); <-done })

	waitChecks := func(n int) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for {
			checks, _ := s.seen()
			if len(checks) >= n {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("the machine checked %d times, want %d", len(checks), n)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	waitChecks(1)
	time.Sleep(300 * time.Millisecond)
	if checks, _ := s.seen(); len(checks) != 1 {
		t.Fatalf("the machine checked %d times before the wake, want 1", len(checks))
	}
	mu.Lock()
	l := conns
	mu.Unlock()
	if l == nil {
		t.Fatal("run made no link")
	}
	l.Wake()
	waitChecks(2)
	checks, _ := s.seen()
	if checks[1] == checks[0] {
		t.Fatalf("the check after the wake went on the connection from before it (%s)", checks[0])
	}
}
