package link

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func get(t *testing.T, c *http.Client, url string) string {
	t.Helper()
	resp, err := c.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.Header.Get("X-Remote")
}

func remoteServer(t *testing.T) *httptest.Server {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Remote", r.RemoteAddr)
	}))
	t.Cleanup(ts.Close)
	return ts
}

func TestDropClosesTheConnectionsOnceAGeneration(t *testing.T) {
	ts := remoteServer(t)
	l := New(Options{})
	c := &http.Client{Transport: l}
	first := get(t, c, ts.URL)
	if again := get(t, c, ts.URL); again != first {
		t.Fatalf("a second request went on a new connection (%s, then %s) with no drop", first, again)
	}
	gen := l.Gen()
	if !l.Drop(gen) {
		t.Fatal("Drop at the current generation didn't drop")
	}
	second := get(t, c, ts.URL)
	if second == first {
		t.Fatal("the request after Drop went on the dropped connection")
	}
	// A second failure from before the drop leaves the new connection be:
	// the requests already retrying on it aren't cut short again.
	if l.Drop(gen) {
		t.Fatal("Drop at an old generation dropped again")
	}
	if third := get(t, c, ts.URL); third != second {
		t.Fatalf("a stale Drop closed the new connection (%s, then %s)", second, third)
	}
	if l.Dials() != 2 {
		t.Fatalf("dials = %d, want 2", l.Dials())
	}
}

func TestALinkPingsByDefault(t *testing.T) {
	// The daemon makes its link with no ping settings (cli's newLink), so
	// the defaults are what turns the pings on in production (#2822): 15 s
	// of quiet, 10 s for the answer.
	cases := []struct {
		name           string
		opts           Options
		after, timeout time.Duration
	}{
		{"no options", Options{}, 15 * time.Second, 10 * time.Second},
		{"its own times", Options{PingAfter: 300 * time.Millisecond, PingTimeout: 200 * time.Millisecond}, 300 * time.Millisecond, 200 * time.Millisecond},
		{"its own quiet time only", Options{PingAfter: time.Second}, time.Second, 10 * time.Second},
		{"its own answer time only", Options{PingTimeout: time.Second}, 15 * time.Second, time.Second},
		{"pings off", Options{PingAfter: -1}, 0, 10 * time.Second},
		{"a negative answer time", Options{PingTimeout: -1}, 15 * time.Second, 10 * time.Second},
	}
	for _, c := range cases {
		l := New(c.opts)
		after, timeout := l.Pings()
		if after != c.after || timeout != c.timeout {
			t.Errorf("%s: pings after %s, answered within %s; want %s and %s", c.name, after, timeout, c.after, c.timeout)
		}
		// Pings reads the transport's own settings: what Go's HTTP/2 uses.
		if h2 := l.t.HTTP2; h2 == nil || h2.SendPingTimeout != c.after || h2.PingTimeout != c.timeout {
			t.Errorf("%s: the transport's HTTP/2 settings are %+v", c.name, h2)
		}
	}
}

func TestAClosedConnectionLeavesTheLinksSet(t *testing.T) {
	// The link keeps a connection only while it is open (#2822): one left
	// in the set would be closed again by every Drop, and a daemon that
	// runs for months would keep one for every reconnect.
	ts := remoteServer(t)
	l := New(Options{PingAfter: -1})
	c := &http.Client{Transport: l}
	open := func() int {
		l.mu.Lock()
		defer l.mu.Unlock()
		return len(l.conns)
	}
	get(t, c, ts.URL)
	if open() != 1 {
		t.Fatalf("the link holds %d connections after a request, want 1", open())
	}
	l.Drop(l.Gen())
	if open() != 0 {
		t.Fatalf("the link still holds %d connections after Drop", open())
	}
	// Closed from the other end: the transport closes its side, and the
	// link forgets it without a Drop.
	get(t, c, ts.URL)
	if open() != 1 {
		t.Fatalf("the link holds %d connections after the request that followed Drop, want 1", open())
	}
	ts.CloseClientConnections()
	deadline := time.Now().Add(5 * time.Second)
	for open() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("the link still holds %d connections after the server closed them", open())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if l.Dials() != 2 {
		t.Fatalf("dials = %d, want 2", l.Dials())
	}
}

func TestWakeDropsAndEndsThePausesWaitingOnIt(t *testing.T) {
	ts := remoteServer(t)
	l := New(Options{})
	c := &http.Client{Transport: l}
	first := get(t, c, ts.URL)
	woken := l.Woken()
	ended := make(chan bool)
	go func() {
		woke, err := Pause(context.Background(), func(ctx context.Context, d time.Duration) error {
			<-ctx.Done()
			return ctx.Err()
		}, woken, time.Hour)
		ended <- woke && err == nil
	}()
	l.Wake()
	select {
	case ok := <-ended:
		if !ok {
			t.Fatal("the pause ended without saying it was woken")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Wake didn't end the pause")
	}
	if get(t, c, ts.URL) == first {
		t.Fatal("the request after Wake went on the connection from before it")
	}
	if l.Woken() == woken {
		t.Fatal("Woken is the same channel after a wake: the next wake would find it closed")
	}
}

func TestPause(t *testing.T) {
	quick := func(ctx context.Context, d time.Duration) error { return nil }
	if woke, err := Pause(context.Background(), quick, nil, time.Second); woke || err != nil {
		t.Fatalf("no waker: %v %v", woke, err)
	}
	if woke, err := Pause(context.Background(), quick, make(chan struct{}), time.Second); woke || err != nil {
		t.Fatalf("a pause that ran out: %v %v", woke, err)
	}
	closed := make(chan struct{})
	close(closed)
	if woke, err := Pause(context.Background(), func(context.Context, time.Duration) error {
		t.Fatal("slept although already woken")
		return nil
	}, closed, time.Second); !woke || err != nil {
		t.Fatalf("already woken: %v %v", woke, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	blocking := func(ctx context.Context, d time.Duration) error { <-ctx.Done(); return ctx.Err() }
	if woke, err := Pause(ctx, blocking, make(chan struct{}), time.Second); woke || !errors.Is(err, context.Canceled) {
		t.Fatalf("ctx ended: %v %v", woke, err)
	}
	stop := errors.New("stop")
	if woke, err := Pause(context.Background(), func(context.Context, time.Duration) error { return stop }, make(chan struct{}), time.Second); woke || err != stop {
		t.Fatalf("a sleep's own error: %v %v", woke, err)
	}
}

func TestJumped(t *testing.T) {
	t0 := time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC)
	every, over := 5*time.Second, 15*time.Second
	cases := []struct {
		name string
		wall time.Duration // the wall clock's move
		mono time.Duration // the monotonic clock's
		want bool
	}{
		{"on time", 5 * time.Second, 5 * time.Second, false},
		{"a little late", 12 * time.Second, 12 * time.Second, false},
		{"slept an hour, monotonic stood still (Linux, macOS)", time.Hour + 5*time.Second, 5 * time.Second, true},
		{"slept an hour, monotonic counted it (Windows)", time.Hour, time.Hour, true},
		{"the clock set back", -time.Minute, 5 * time.Second, true},
		{"an NTP nudge", 6 * time.Second, 5 * time.Second, false},
	}
	for _, c := range cases {
		gap, got := Jumped(t0, 0, t0.Add(c.wall), c.mono, every, over)
		if got != c.want {
			t.Errorf("%s: jumped = %v (gap %s), want %v", c.name, got, gap, c.want)
		}
	}
}

func TestWatchClockWakesOnAJumpOnly(t *testing.T) {
	var wall time.Time
	var mono time.Duration
	tick := make(chan struct{}, 100)
	jump := make(chan time.Duration, 1)
	clock := func() (time.Time, time.Duration) {
		select {
		case d := <-jump:
			wall = wall.Add(d)
		default:
		}
		wall, mono = wall.Add(10*time.Millisecond), mono+10*time.Millisecond
		tick <- struct{}{}
		return wall, mono
	}
	l := New(Options{Clock: clock, ClockEvery: 10 * time.Millisecond, JumpOver: time.Second})
	woken := l.Woken()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var logged []string
	done := make(chan struct{})
	go func() {
		defer close(done)
		l.WatchClock(ctx, func(f string, a ...any) { logged = append(logged, f) })
	}()
	for i := 0; i < 10; i++ {
		<-tick
	}
	select {
	case <-woken:
		t.Fatal("woke with the clock on time")
	default:
	}
	jump <- time.Hour
	select {
	case <-woken:
	case <-time.After(5 * time.Second):
		t.Fatal("the clock jumped an hour and the link didn't wake")
	}
	cancel()
	<-done
	if len(logged) != 1 {
		t.Fatalf("logged %d lines, want one for the jump", len(logged))
	}
}
