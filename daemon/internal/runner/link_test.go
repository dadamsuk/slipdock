package runner

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/link"
)

// The daemon's channel to the server (#2807), through the runner's claim
// loop, against an HTTP/2 server over TLS whose connections the test can
// black-hole: still open, reading and dropping whatever comes, answering
// nothing, as a connection whose route moved to another anycast site does.

// holeConn is the server's side of one connection. Silenced, it swallows
// what the client sends and sends nothing back; closed tells when the
// client gave the connection up (its reads end).
type holeConn struct {
	net.Conn
	silent    atomic.Bool
	closed    chan struct{}
	quit      <-chan struct{} // the test ending: a held claim lets go
	closeOnce sync.Once
}

func (c *holeConn) Read(p []byte) (int, error) {
	for {
		n, err := c.Conn.Read(p)
		if err != nil {
			c.closeOnce.Do(func() { close(c.closed) })
			return n, err
		}
		if !c.silent.Load() {
			return n, nil
		}
	}
}

func (c *holeConn) Write(p []byte) (int, error) {
	if c.silent.Load() {
		return len(p), nil
	}
	return c.Conn.Write(p)
}

type holeListener struct {
	net.Listener
	mu    sync.Mutex
	conns map[string]*holeConn
	quit  chan struct{}
}

func (l *holeListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	hc := &holeConn{Conn: c, closed: make(chan struct{}), quit: l.quit}
	l.mu.Lock()
	l.conns[c.RemoteAddr().String()] = hc
	l.mu.Unlock()
	return hc, nil
}

func (l *holeListener) conn(addr string) *holeConn {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.conns[addr]
}

// claimSeen is one claim the server read: which connection, and when.
type claimSeen struct {
	addr string
	at   time.Time
	h2   bool
}

type holeServer struct {
	ts     *httptest.Server
	ln     *holeListener
	mu     sync.Mutex
	claims []claimSeen
	// answer answers the n-th claim (from 1), seen on the connection c.
	answer func(n int, c *holeConn, w http.ResponseWriter, r *http.Request)
}

func newHoleServer(t *testing.T, answer func(n int, c *holeConn, w http.ResponseWriter, r *http.Request)) *holeServer {
	t.Helper()
	s := &holeServer{answer: answer}
	s.ts = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/runner/claim") {
			http.NotFound(w, r)
			return
		}
		s.mu.Lock()
		s.claims = append(s.claims, claimSeen{addr: r.RemoteAddr, at: time.Now(), h2: r.ProtoMajor == 2})
		n := len(s.claims)
		s.mu.Unlock()
		s.answer(n, s.ln.conn(r.RemoteAddr), w, r)
	}))
	s.ln = &holeListener{Listener: s.ts.Listener, conns: map[string]*holeConn{}, quit: make(chan struct{})}
	s.ts.Listener = s.ln
	s.ts.EnableHTTP2 = true
	s.ts.StartTLS()
	t.Cleanup(s.ts.Close)
	// Before Close, which waits for the held claims.
	t.Cleanup(func() { close(s.ln.quit) })
	return s
}

func (s *holeServer) seen() []claimSeen {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]claimSeen(nil), s.claims...)
}

// waitFor waits up to d for the server to have read n claims.
func (s *holeServer) waitFor(t *testing.T, n int, d time.Duration) []claimSeen {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if c := s.seen(); len(c) >= n {
			return c
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("the server read %d claims in %s, want %d", len(s.seen()), d, n)
	return nil
}

// linkWorker is a worker claiming from s over a link with opts.
func linkWorker(t *testing.T, s *holeServer, opts link.Options) (*Worker, *link.Link) {
	t.Helper()
	opts.TLS = s.ts.Client().Transport.(*http.Transport).TLSClientConfig
	l := link.New(opts)
	w := &Worker{
		Runner:   Runner{ID: 11, Name: "builder", BoardID: 3, Pool: "default", Config: Config{Agent: "claude", Executor: "me"}},
		Client:   &Client{Server: s.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{Transport: l}, Conns: l},
		Version:  "test",
		JobsDir:  t.TempDir(),
		Home:     t.TempDir(),
		Logf:     t.Logf,
		Getenv:   func(string) string { return "" },
		LookPath: func(name string) (string, error) { return "", &net.AddrError{Err: "not found", Addr: name} },
		Wait:     1,
	}
	return w, l
}

// runWorker runs w until the test ends.
func runWorker(t *testing.T, w *Worker) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = w.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
}

// silenceSecond answers the first claim at once. The second, on the same
// connection, is held as a long-poll is, and its connection goes silent
// while it waits: a claim in flight on a connection that has died. Later
// claims are answered at once.
func silenceSecond(n int, c *holeConn, w http.ResponseWriter, r *http.Request) {
	if n == 2 {
		c.silent.Store(true)
		select {
		case <-r.Context().Done():
		case <-c.quit:
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// afterTheSilence checks that the claim held when the connection died was
// on the first connection, and that the claim after it is on a new one,
// with the dead one given up at the client. It returns how long the
// retry took after the silence.
func afterTheSilence(t *testing.T, s *holeServer, within time.Duration) time.Duration {
	t.Helper()
	seen := s.waitFor(t, 3, within)
	if !seen[0].h2 {
		t.Fatal("the claims weren't over HTTP/2: the test isn't testing the link")
	}
	if seen[1].addr != seen[0].addr {
		t.Fatal("the held claim wasn't on the first connection: the test isn't testing a dead connection")
	}
	if seen[2].addr == seen[1].addr {
		t.Fatalf("the claim after the silence was read on the dead connection %s", seen[1].addr)
	}
	select {
	case <-s.ln.conn(seen[1].addr).closed:
	default:
		t.Fatal("the dead connection is still open at the client: it could be used again")
	}
	return seen[2].at.Sub(seen[1].at)
}

func TestADeadConnectionIsNoticedByItsPingsAndReplaced(t *testing.T) {
	s := newHoleServer(t, silenceSecond)
	w, l := linkWorker(t, s, link.Options{PingAfter: 300 * time.Millisecond, PingTimeout: 500 * time.Millisecond})
	runWorker(t, w)

	took := afterTheSilence(t, s, 60*time.Second)
	if took > 60*time.Second {
		t.Fatalf("claiming again took %s, want within 60 s", took)
	}
	// Well inside the held claim's own deadline (its wait and PollSlack):
	// the pings noticed the dead connection, not the claim timing out.
	if took >= time.Duration(w.Wait)*time.Second+PollSlack {
		t.Fatalf("claiming again took %s: the claim's deadline, not the pings, gave the connection up", took)
	}
	// Nothing more goes on the dead one: every later claim is on the new.
	seen := s.waitFor(t, 5, 10*time.Second)
	for _, c := range seen[2:] {
		if c.addr == seen[1].addr {
			t.Fatalf("a claim went on the dead connection after it was given up: %+v", c)
		}
	}
	if l.Dials() != 2 {
		t.Fatalf("the link dialled %d connections, want 2 (the dead one and its replacement)", l.Dials())
	}
}

func TestAClaimThatTimesOutIsTriedAgainOnANewConnection(t *testing.T) {
	// No pings: only the claim's deadline notices the dead connection, and
	// the retry must not go back on it, as Go would put it there.
	old := PollSlack
	PollSlack = 500 * time.Millisecond
	t.Cleanup(func() { PollSlack = old })
	s := newHoleServer(t, silenceSecond)
	w, l := linkWorker(t, s, link.Options{PingAfter: -1})
	runWorker(t, w)

	afterTheSilence(t, s, 30*time.Second)
	if l.Dials() != 2 {
		t.Fatalf("the link dialled %d connections, want 2", l.Dials())
	}
}

func TestNothingSentOnABlackHoledConnectionReachesTheServer(t *testing.T) {
	// A check on the fake server (#2807), with a plain client and no link:
	// once a connection is silenced, nothing more sent on it is read. Up
	// to Go 1.26 a plain client puts every retry back on it, so no claim
	// is read after the held one, the bug the link fixes; from Go 1.27 its
	// transport sometimes checks a connection after a cancelled request
	// and moves to a new one, where its claims are read. Either way none
	// is read on the dead connection.
	old := PollSlack
	PollSlack = 300 * time.Millisecond
	t.Cleanup(func() { PollSlack = old })
	s := newHoleServer(t, silenceSecond)
	w, _ := linkWorker(t, s, link.Options{PingAfter: -1})
	tr := s.ts.Client().Transport.(*http.Transport).Clone()
	tr.ForceAttemptHTTP2 = true
	w.Client = &Client{Server: s.ts.URL, Key: "k", HTTP: &http.Client{Transport: tr}}
	runWorker(t, w)
	held := s.waitFor(t, 2, 10*time.Second)[1]
	time.Sleep(4 * time.Second)
	for _, c := range s.seen()[2:] {
		if c.addr == held.addr {
			t.Fatalf("a claim was read on the silenced connection %s: the fake server isn't black-holing it", held.addr)
		}
	}
}

func TestPingsLeaveAHealthyLongPollAlone(t *testing.T) {
	// Each claim is held a second and a half, as the server holds a
	// long-poll, with a ping every 200 ms of quiet: every ping is answered,
	// and every claim goes on the one connection.
	s := newHoleServer(t, func(_ int, c *holeConn, w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(1500 * time.Millisecond):
		case <-r.Context().Done():
		case <-c.quit:
		}
		w.WriteHeader(http.StatusNoContent)
	})
	w, l := linkWorker(t, s, link.Options{PingAfter: 200 * time.Millisecond, PingTimeout: 500 * time.Millisecond})
	runWorker(t, w)

	seen := s.waitFor(t, 4, 30*time.Second)
	for _, c := range seen {
		if c.addr != seen[0].addr {
			t.Fatalf("claims went on more than one connection: %+v", seen)
		}
	}
	if l.Dials() != 1 {
		t.Fatalf("the link dialled %d connections over %d polls, want 1", l.Dials(), len(seen))
	}
}

func TestAClockJumpDropsTheConnectionAndClaimsAtOnce(t *testing.T) {
	// The server is down for deploys: every claim answers 503. The worker
	// backs off, 1, 2 and 4 s (passed at once here), then 8 s, a pause only
	// a wake ends. Then the wall clock jumps an hour (the machine slept):
	// the claim comes at once, on a new connection, and the backoff starts
	// again from a second.
	s := newHoleServer(t, func(_ int, _ *holeConn, w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	var clockMu sync.Mutex
	wall, mono := time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC), time.Duration(0)
	clock := func() (time.Time, time.Duration) {
		clockMu.Lock()
		defer clockMu.Unlock()
		wall, mono = wall.Add(10*time.Millisecond), mono+10*time.Millisecond
		return wall, mono
	}
	w, l := linkWorker(t, s, link.Options{PingAfter: -1, Clock: clock, ClockEvery: 10 * time.Millisecond, JumpOver: time.Second})
	var mu sync.Mutex
	var slept []time.Duration
	w.Sleep = func(ctx context.Context, d time.Duration) error {
		mu.Lock()
		slept = append(slept, d)
		n := len(slept)
		mu.Unlock()
		if n <= 3 {
			return nil
		}
		<-ctx.Done()
		return ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go l.WatchClock(ctx, t.Logf)
	runWorker(t, w)

	s.waitFor(t, 4, 10*time.Second)
	time.Sleep(200 * time.Millisecond)
	if n := len(s.seen()); n != 4 {
		t.Fatalf("the worker claimed %d times before the clock jumped, want 4 (it waits out its backoff)", n)
	}
	clockMu.Lock()
	wall = wall.Add(time.Hour)
	clockMu.Unlock()

	seen := s.waitFor(t, 5, 5*time.Second)
	if seen[4].addr == seen[3].addr {
		t.Fatal("the claim after the wake went on the connection from before the sleep")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		n := len(slept)
		got := append([]time.Duration(nil), slept...)
		mu.Unlock()
		if n >= 5 {
			want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, time.Second}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("backoffs = %v, want %v: doubling, then a second again after the wake", got, want)
				}
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("backoffs = %v, want five", got)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
