// Package link is the daemon's channel to its server (#2807): one HTTP
// transport that every long-poll, report and enrolment check shares, made
// to notice a dead connection in seconds and replace it.
//
// A connection can die silently: a route change between the anycast sites
// in front of the server leaves our packets landing where nobody knows the
// flow, with no reset and no FIN; a laptop sleeps, changes Wi-Fi or turns a
// VPN on. Go would keep such an HTTP/2 connection, and put every retry back
// on it, until the kernel gave up on the socket (about 16 minutes). So:
//
//   - HTTP/2 pings (Go 1.24's http.Transport.HTTP2): a connection quiet for
//     PingAfter is pinged, and closed if no answer comes within PingTimeout.
//     Its requests then fail at once and are tried again on a new one.
//   - Drop closes every open connection, for a caller whose request hit its
//     deadline or a transport error, so the retry dials afresh.
//   - WatchClock notices the wall clock jump (the machine woke from sleep)
//     and wakes the link: connections dropped, and every pause waiting on
//     Woken ends, so the daemon is back in its pools within seconds.
package link

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"sync"
	"time"
)

// Defaults for Options. A healthy server answers a ping in milliseconds,
// so 15 s of quiet and 10 s for the answer is a dead connection noticed in
// at most 25 s, and a long-poll's quiet connection pinged once or twice.
const (
	PingAfter   = 15 * time.Second
	PingTimeout = 10 * time.Second
	ClockEvery  = 5 * time.Second
	JumpOver    = 15 * time.Second
)

// Options shape a Link. Zero values take the defaults above; a negative
// PingAfter turns the pings off.
type Options struct {
	PingAfter   time.Duration
	PingTimeout time.Duration
	// TLS is the client's TLS config (a test's server's roots); nil is the
	// system's.
	TLS *tls.Config
	// Clock reads the wall clock and a monotonic one; tests give their own.
	Clock func() (wall time.Time, mono time.Duration)
	// ClockEvery is how often WatchClock reads the clock, and JumpOver how
	// far the wall clock may move apart from the monotonic one (or a read
	// come late) before it counts as a jump.
	ClockEvery time.Duration
	JumpOver   time.Duration
}

// Link is an http.RoundTripper over one transport whose connections it
// tracks, so it can close them all.
type Link struct {
	t    *http.Transport
	opts Options

	mu    sync.Mutex
	conns map[*conn]struct{}
	gen   uint64
	woken chan struct{}
	dials int
}

// New is a link with opts' settings.
func New(opts Options) *Link {
	if opts.PingAfter == 0 {
		opts.PingAfter = PingAfter
	}
	if opts.PingTimeout <= 0 {
		opts.PingTimeout = PingTimeout
	}
	if opts.ClockEvery <= 0 {
		opts.ClockEvery = ClockEvery
	}
	if opts.JumpOver <= 0 {
		opts.JumpOver = JumpOver
	}
	if opts.Clock == nil {
		opts.Clock = systemClock()
	}
	l := &Link{opts: opts, conns: map[*conn]struct{}{}, woken: make(chan struct{})}
	t := http.DefaultTransport.(*http.Transport).Clone()
	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 15 * time.Second}
	t.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := dialer.DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		return l.track(c), nil
	}
	t.ForceAttemptHTTP2 = true
	if opts.TLS != nil {
		t.TLSClientConfig = opts.TLS.Clone()
	}
	h2 := &http.HTTP2Config{PingTimeout: opts.PingTimeout}
	if opts.PingAfter > 0 {
		h2.SendPingTimeout = opts.PingAfter
	}
	t.HTTP2 = h2
	l.t = t
	return l
}

// RoundTrip sends req over the link's transport.
func (l *Link) RoundTrip(req *http.Request) (*http.Response, error) {
	return l.t.RoundTrip(req)
}

// CloseIdleConnections closes the transport's idle connections.
func (l *Link) CloseIdleConnections() { l.t.CloseIdleConnections() }

// Gen is the link's generation: one more after every Drop. A caller reads
// it before a request, and gives it to Drop after the request fails.
func (l *Link) Gen() uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.gen
}

// Drop closes every open connection, so the next request dials a new one,
// unless the link was dropped since gen: then the connection the failed
// request was on is gone already, and dropping again would only cut short
// the requests already retrying on a new one. It says whether it dropped.
func (l *Link) Drop(gen uint64) bool {
	l.mu.Lock()
	if gen != l.gen {
		l.mu.Unlock()
		return false
	}
	l.gen++
	open := make([]*conn, 0, len(l.conns))
	for c := range l.conns {
		open = append(open, c)
	}
	l.mu.Unlock()
	for _, c := range open {
		c.Close()
	}
	l.t.CloseIdleConnections()
	return true
}

// Woken is closed when the link next wakes (Wake): a pause selects on it
// to end early. Read it before the request whose failure the pause
// follows, so a wake while that request was failing ends the pause at once.
func (l *Link) Woken() <-chan struct{} {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.woken
}

// Wake drops every connection and ends every pause waiting on Woken: the
// machine has woken from sleep, or its network changed, and nothing the
// link had open can be trusted.
func (l *Link) Wake() {
	l.Drop(l.Gen())
	l.mu.Lock()
	close(l.woken)
	l.woken = make(chan struct{})
	l.mu.Unlock()
}

// Pings is what the link's transport was told: a connection quiet for
// after is pinged, and closed with no answer within timeout. after is 0
// when the pings are off.
func (l *Link) Pings() (after, timeout time.Duration) {
	return l.t.HTTP2.SendPingTimeout, l.t.HTTP2.PingTimeout
}

// Dials is how many connections the link has opened.
func (l *Link) Dials() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.dials
}

// WatchClock reads the clock every ClockEvery until ctx ends, and wakes the
// link when the wall clock has jumped: moved more than JumpOver apart from
// the monotonic clock, which stands still while a machine sleeps (Linux,
// macOS), or a read come more than JumpOver late, as it does where the
// monotonic clock counts the sleep (Windows). logf says why.
func (l *Link) WatchClock(ctx context.Context, logf func(string, ...any)) {
	t := time.NewTicker(l.opts.ClockEvery)
	defer t.Stop()
	wall, mono := l.opts.Clock()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		w, m := l.opts.Clock()
		if gap, ok := Jumped(wall, mono, w, m, l.opts.ClockEvery, l.opts.JumpOver); ok {
			logf("warn: the clock jumped %s (the machine slept, or its clock was set): dropping the connections to the server and trying again now", gap.Round(time.Second))
			l.Wake()
		}
		wall, mono = w, m
	}
}

// Jumped says whether two clock reads every apart show a jump of more than
// over, and how big: the wall clock moving apart from the monotonic one, or
// the monotonic one itself moving much more than every.
func Jumped(wall0 time.Time, mono0 time.Duration, wall1 time.Time, mono1 time.Duration, every, over time.Duration) (time.Duration, bool) {
	dm := mono1 - mono0
	gap := wall1.Sub(wall0) - dm
	if gap < 0 {
		gap = -gap
	}
	if gap > over {
		return gap, true
	}
	if late := dm - every; late > over {
		return late, true
	}
	return 0, false
}

func systemClock() func() (time.Time, time.Duration) {
	start := time.Now()
	return func() (time.Time, time.Duration) {
		now := time.Now()
		// Round(0) strips the monotonic reading: the wall clock alone.
		return now.Round(0), now.Sub(start)
	}
}

func (l *Link) track(c net.Conn) net.Conn {
	tc := &conn{Conn: c, l: l}
	l.mu.Lock()
	l.conns[tc] = struct{}{}
	l.dials++
	l.mu.Unlock()
	return tc
}

// conn is a connection the link knows about until it is closed.
type conn struct {
	net.Conn
	l    *Link
	once sync.Once
}

func (c *conn) Close() error {
	c.once.Do(func() {
		c.l.mu.Lock()
		delete(c.l.conns, c)
		c.l.mu.Unlock()
	})
	return c.Conn.Close()
}

// Pause waits d with sleep, ending early, with woke true, when woken is
// closed (nil never is). err is ctx's when ctx ended.
func Pause(ctx context.Context, sleep func(context.Context, time.Duration) error, woken <-chan struct{}, d time.Duration) (woke bool, err error) {
	if woken == nil {
		return false, sleep(ctx, d)
	}
	select {
	case <-woken:
		return true, nil
	default:
	}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		select {
		case <-woken:
			cancel()
		case <-sctx.Done():
		}
	}()
	err = sleep(sctx, d)
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	select {
	case <-woken:
		return true, nil
	default:
	}
	return false, err
}
