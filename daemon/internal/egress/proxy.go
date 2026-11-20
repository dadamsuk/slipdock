package egress

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Proxy is one job's: an HTTP proxy on 127.0.0.1 (and, for a container
// job, on a unix socket mounted into it) that takes CONNECT and plain
// HTTP requests and lets through only those to a host and port its rules
// allow. A refused one gets 403, and the job's log says so, once per host.
type Proxy struct {
	mu     sync.Mutex
	rules  []Rule
	denied map[string]bool
	logf   func(string)
	tcp    net.Listener
	unix   net.Listener
	srv    *http.Server
	conns  map[net.Conn]struct{}
	closed bool
	// dial reaches an allowed host (a test points it elsewhere).
	dial func(ctx context.Context, network, addr string) (net.Conn, error)
	// tripwire is the job's fake credentials (#3524), onTrip what is done
	// the first time one is seen.
	tripwire *Tripwire
	onTrip   func(what string)
	tripped  bool
}

const dialTimeout = 30 * time.Second

// listenTCP is net.Listen, for the proxy's port: a test's stands in.
var listenTCP = net.Listen

// quiet: what goes wrong for a job is the job's to see, not the daemon's log.
var quiet = log.New(io.Discard, "", 0)

// Start listens on a random port of 127.0.0.1, and on socket when it
// isn't "", and serves until Close. logf gets each line for the job's log.
func Start(rules []Rule, socket string, logf func(string)) (*Proxy, error) {
	return start(rules, socket, logf, nil)
}

// start is Start, with dial (when not nil) in place of the real dialler.
func start(rules []Rule, socket string, logf func(string),
	dial func(ctx context.Context, network, addr string) (net.Conn, error)) (*Proxy, error) {
	if logf == nil {
		logf = func(string) {}
	}
	p := &Proxy{rules: append([]Rule(nil), rules...), denied: map[string]bool{}, logf: logf,
		conns: map[net.Conn]struct{}{}}
	p.dial = dial
	if p.dial == nil {
		d := &net.Dialer{Timeout: dialTimeout, Control: p.refuseLoopback}
		p.dial = d.DialContext
	}
	tcp, err := listenTCP("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p.tcp = tcp
	if socket != "" {
		u, err := net.Listen("unix", socket)
		if err != nil {
			tcp.Close()
			return nil, err
		}
		_ = os.Chmod(socket, 0o600)
		p.unix = u
	}
	p.srv = &http.Server{Handler: p, ReadHeaderTimeout: dialTimeout, ErrorLog: quiet}
	go p.srv.Serve(tcp)
	if p.unix != nil {
		go p.srv.Serve(p.unix)
	}
	return p, nil
}

// Port is the proxy's port on 127.0.0.1.
func (p *Proxy) Port() int { return p.tcp.Addr().(*net.TCPAddr).Port }

// Allow adds rules: the repository's origin, once it is known.
func (p *Proxy) Allow(rules ...Rule) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.rules = append(p.rules, rules...)
}

// Rules are what the proxy lets through.
func (p *Proxy) Rules() []Rule {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]Rule(nil), p.rules...)
}

// Watch has the proxy look for t's values in what the job sends, and
// call on (once, the first time) with which one it saw and where. A
// request carrying one is refused, and a connection carrying one closed.
func (p *Proxy) Watch(t *Tripwire, on func(what string)) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tripwire, p.onTrip = t, on
}

func (p *Proxy) watched() *Tripwire {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.tripwire
}

// trip is one of the job's fake credentials, seen going to target.
func (p *Proxy) trip(what, target string) {
	p.mu.Lock()
	first, on := !p.tripped, p.onTrip
	p.tripped = true
	p.mu.Unlock()
	if !first {
		return
	}
	if len(target) > 100 {
		target = target[:100] + "…"
	}
	what = what + ", going to " + target
	p.logf("slipdock-runner: tripwire: the job's fake credentials were seen leaving (" + what + ")")
	if on != nil {
		on(what)
	}
}

// Close stops the proxy and every connection through it.
func (p *Proxy) Close() error {
	p.mu.Lock()
	p.closed = true
	conns := p.conns
	p.conns = map[net.Conn]struct{}{}
	p.mu.Unlock()
	for c := range conns {
		c.Close()
	}
	return p.srv.Close()
}

// allowed says whether a rule lets host:port through, and logs it (once
// per target) when none does.
func (p *Proxy) allowed(host string, port int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, r := range p.rules {
		if r.Allows(host, port) {
			return true
		}
	}
	target := net.JoinHostPort(host, strconv.Itoa(port))
	if !p.denied[target] {
		p.denied[target] = true
		p.logf(fmt.Sprintf("slipdock-runner: network allowlist: refused a connection to %s, which isn't on the job's allowlist", target))
	}
	return false
}

// loopbackAllowed: the rules name a port of the machine itself.
func (p *Proxy) loopbackAllowed(port int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, r := range p.rules {
		if r.Loopback() && r.Port == port {
			return true
		}
	}
	return false
}

// refuseLoopback stops an allowed name that resolves to the machine
// itself reaching its services (the proxy among them), unless the rules
// name that port of localhost.
func (p *Proxy) refuseLoopback(_, address string, _ syscall.RawConn) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	n, _ := strconv.Atoi(port)
	if ip != nil && (ip.IsLoopback() || ip.IsUnspecified()) && !p.loopbackAllowed(n) {
		return fmt.Errorf("%s is this machine, which the allowlist doesn't name", address)
	}
	return nil
}

// target is a request's host and port, as the job named it.
func target(hostport string, defaultPort int) (string, int, error) {
	host, port := hostport, defaultPort
	if h, ps, err := net.SplitHostPort(hostport); err == nil {
		n, err := strconv.Atoi(ps)
		if err != nil || n < 1 || n > 65535 {
			return "", 0, fmt.Errorf("%q: no such port", hostport)
		}
		host, port = h, n
	} else if defaultPort == 0 {
		return "", 0, fmt.Errorf("%q: CONNECT names a port", hostport)
	}
	if host == "" || strings.ContainsAny(host, " /\\@") {
		return "", 0, fmt.Errorf("%q is not a host", hostport)
	}
	return host, port, nil
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Before anything else: a value smuggled in a name the allowlist
	// refuses is the case to see.
	tw := p.watched()
	if what := tw.inRequest(r); what != "" {
		p.trip(what, r.Host)
		http.Error(w, "slipdock-runner: refused", http.StatusForbidden)
		return
	}
	if r.Method == http.MethodConnect {
		p.connect(w, r)
		return
	}
	if r.URL.Scheme != "http" || r.URL.Host == "" {
		http.Error(w, "slipdock-runner: this is a job's proxy: a CONNECT, or a plain http:// request", http.StatusBadRequest)
		return
	}
	host, port, err := target(r.URL.Host, 80)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if !p.allowed(host, port) {
		http.Error(w, "slipdock-runner: "+r.URL.Host+" is not on this job's network allowlist", http.StatusForbidden)
		return
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	if tw != nil && r.Body != nil && r.Body != http.NoBody {
		r.Body = struct {
			io.Reader
			io.Closer
		}{tw.scan(r.Body, "the request's body", func(what string) { p.trip(what, addr) }), r.Body}
	}
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme, pr.Out.URL.Host = "http", addr
			pr.Out.Host = "" // the host allowed, never another in a header
			pr.Out.Header.Del("Proxy-Authorization")
		},
		Transport: &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return p.dial(ctx, network, addr)
		}},
		ErrorLog: quiet,
	}
	rp.ServeHTTP(w, r)
}

func (p *Proxy) connect(w http.ResponseWriter, r *http.Request) {
	host, port, err := target(r.Host, 0)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if !p.allowed(host, port) {
		http.Error(w, "slipdock-runner: "+r.Host+" is not on this job's network allowlist", http.StatusForbidden)
		return
	}
	up, err := p.dial(r.Context(), "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		http.Error(w, "slipdock-runner: "+err.Error(), http.StatusBadGateway)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		up.Close()
		http.Error(w, "can't take over the connection", http.StatusInternalServerError)
		return
	}
	down, buf, err := hj.Hijack()
	if err != nil {
		up.Close()
		return
	}
	if !p.track(up, down) {
		return
	}
	defer p.untrack(up, down)
	if _, err := io.WriteString(down, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		return
	}
	var in io.Reader = buf.Reader
	if tw := p.watched(); tw != nil {
		// What the job sends through the tunnel: plain text is seen, TLS
		// isn't. Seen, the read fails and the tunnel closes.
		in = tw.scan(in, "what the job sent through the tunnel", func(what string) {
			p.trip(what, r.Host)
			// Closing the upstream ends the other copy too, so the
			// splice returns and untrack closes the job's end: the
			// tunnel ends even if the upstream never hangs up.
			up.Close()
		})
	}
	splice(up, down, in)
}

func (p *Proxy) track(conns ...net.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		for _, c := range conns {
			c.Close()
		}
		return false
	}
	for _, c := range conns {
		p.conns[c] = struct{}{}
	}
	return true
}

func (p *Proxy) untrack(conns ...net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range conns {
		delete(p.conns, c)
		c.Close()
	}
}

// splice copies both ways until either side is done. in reads down (what
// was read from it already, past the request, first).
func splice(up, down net.Conn, in io.Reader) {
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(up, in)
		closeWrite(up)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(down, up)
		closeWrite(down)
		done <- struct{}{}
	}()
	<-done
	<-done
}

func closeWrite(c net.Conn) {
	type cw interface{ CloseWrite() error }
	if x, ok := c.(cw); ok {
		_ = x.CloseWrite()
		return
	}
	_ = c.Close()
}

// ErrDenied is the proxy's refusal, as connect sees it.
var ErrDenied = errors.New("refused by the job's network allowlist")
