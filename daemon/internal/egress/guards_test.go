package egress

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Each way the proxy and its helpers can fail, and what each answers.

// oneShot listens on 127.0.0.1 and answers the first connection with
// reply (none: it closes at once).
func oneShot(t *testing.T, reply string) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		_, _ = bufio.NewReader(c).ReadString('\n')
		if reply != "" {
			_, _ = io.WriteString(c, reply)
		}
		c.Close()
	}()
	return l.Addr().String()
}

func TestConnectSaysWhyItGotNoTunnel(t *testing.T) {
	// No proxy there.
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	gone := l.Addr().String()
	l.Close()
	if err := Connect(gone, "example.com", "22", strings.NewReader(""), io.Discard); err == nil {
		t.Fatal("no proxy: no error")
	}
	// A proxy that hangs up without answering.
	if err := Connect(oneShot(t, ""), "example.com", "22", strings.NewReader(""), io.Discard); err == nil {
		t.Fatal("a proxy that hung up: no error")
	}
	// A proxy that answers anything but 200 or 403.
	err := Connect(oneShot(t, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"), "example.com", "22",
		strings.NewReader(""), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "example.com:22: the proxy said 502 Bad Gateway") || errors.Is(err, ErrDenied) {
		t.Fatalf("a 502: %v", err)
	}
	// A refusal is ErrDenied.
	err = Connect(oneShot(t, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"), "example.com", "22",
		strings.NewReader(""), io.Discard)
	if !errors.Is(err, ErrDenied) {
		t.Fatalf("a 403: %v", err)
	}
}

// mute is a connection to a proxy that can't be written to, whatever it
// would answer.
type mute struct {
	net.Conn
	r io.Reader
}

func (m mute) Read(b []byte) (int, error)  { return m.r.Read(b) }
func (m mute) Write([]byte) (int, error)   { return 0, errors.New("broken pipe") }
func (m mute) Close() error                { return nil }
func (m mute) SetDeadline(time.Time) error { return nil }

func TestConnectStopsWhenItCantAskForATunnel(t *testing.T) {
	defer func(f func(string, string) (net.Conn, error)) { dialProxy = f }(dialProxy)
	dialProxy = func(string, string) (net.Conn, error) {
		return mute{r: strings.NewReader("HTTP/1.1 200 Connection established\r\n\r\n")}, nil
	}
	err := Connect("127.0.0.1:1", "example.com", "22", strings.NewReader("data"), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "broken pipe") {
		t.Fatalf("a CONNECT that couldn't be sent: %v", err)
	}
}

func TestMainNamesItsCommands(t *testing.T) {
	var errs bytes.Buffer
	if code := Main(nil, nil, io.Discard, &errs); code != 2 || !strings.Contains(errs.String(), "usage") {
		t.Fatalf("no command: %d %s", code, errs.String())
	}
	errs.Reset()
	if code := Main([]string{"connect", "127.0.0.1:1"}, nil, io.Discard, &errs); code != 2 ||
		!strings.Contains(errs.String(), "usage: slipdock-runner egress connect PROXY HOST PORT") {
		t.Fatalf("connect with too few: %d %s", code, errs.String())
	}
	errs.Reset()
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	gone := l.Addr().String()
	l.Close()
	if code := Main([]string{"connect", gone, "example.com", "22"}, strings.NewReader(""), io.Discard, &errs); code != 1 ||
		!strings.Contains(errs.String(), "slipdock-runner egress: ") {
		t.Fatalf("connect to no proxy: %d %s", code, errs.String())
	}
	errs.Reset()
	if code := Main([]string{"forward", "--listen"}, nil, io.Discard, &errs); code != 2 ||
		!strings.Contains(errs.String(), "--listen needs a value") {
		t.Fatalf("forward --listen with no value: %d %s", code, errs.String())
	}
	errs.Reset()
	if code := Main([]string{"forward", "--listen", "127.0.0.1:0", "--to", "x", "/bin/true"}, nil, io.Discard, &errs); code != 2 ||
		!strings.Contains(errs.String(), `unexpected "/bin/true"`) {
		t.Fatalf("forward with no --: %d %s", code, errs.String())
	}
	errs.Reset()
	if code := Main([]string{"forward", "--to", "x", "--", "/bin/true"}, nil, io.Discard, &errs); code != 2 ||
		!strings.Contains(errs.String(), "usage: slipdock-runner egress forward") {
		t.Fatalf("forward with no --listen: %d %s", code, errs.String())
	}
	errs.Reset()
	if code := Main([]string{"nope"}, nil, io.Discard, &errs); code != 2 || !strings.Contains(errs.String(), `unexpected "nope"`) {
		t.Fatalf("an unknown command: %d %s", code, errs.String())
	}
}

func TestForwardRunsNoProgramItCantStart(t *testing.T) {
	var errs bytes.Buffer
	code := Main([]string{"forward", "--listen", "127.0.0.1:0", "--to", "x", "--", filepath.Join(t.TempDir(), "missing")},
		nil, io.Discard, &errs)
	if code != 127 || !strings.Contains(errs.String(), "slipdock-runner egress forward: ") {
		t.Fatalf("exit %d %s", code, errs.String())
	}
}

// A connection forward can't carry to the socket is closed, and forward
// carries on.
func TestForwardClosesAConnectionItCantCarry(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix sockets: Linux and macOS")
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listen := l.Addr().String()
	l.Close()
	var errs bytes.Buffer
	// The program dials forward's port twice: forward closes each, and
	// the program still ends as it chose.
	code := Main([]string{"forward", "--listen", listen, "--to", filepath.Join(t.TempDir(), "no.sock"), "--",
		os.Args[0], "helper-dial", listen}, nil, io.Discard, &errs)
	if code != 5 {
		t.Fatalf("exit %d, want the program's 5: %s", code, errs.String())
	}
}

func TestExitStatusIsTheProgramsOrItsSignals(t *testing.T) {
	if exitStatus(nil) != 0 || exitStatus(errors.New("x")) != 1 {
		t.Fatal("no error, or not an exit")
	}
	if runtime.GOOS == "windows" {
		t.Skip("signals: Linux and macOS")
	}
	err := exec.Command("/bin/sh", "-c", "exit 9").Run()
	if got := exitStatus(err); got != 9 {
		t.Fatalf("exit 9: %d", got)
	}
	err = exec.Command("/bin/sh", "-c", "kill -KILL $$").Run()
	if got := exitStatus(err); got != 128+9 {
		t.Fatalf("killed: %d, want 137", got)
	}
}

func TestAProxyWithNoLogStillRefuses(t *testing.T) {
	p, err := Start([]Rule{{"api.example.com", 443}}, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if p.allowed("evil.example.net", 443) {
		t.Fatal("allowed")
	}
}

func TestAProxyWithNoPortDoesntStart(t *testing.T) {
	defer func(f func(string, string) (net.Listener, error)) { listenTCP = f }(listenTCP)
	listenTCP = func(string, string) (net.Listener, error) { return nil, errors.New("no ports left") }
	p, err := Start(nil, "", nil)
	if err == nil || !strings.Contains(err.Error(), "no ports left") {
		if p != nil {
			p.Close()
		}
		t.Fatalf("started with no port: %v", err)
	}
}

func TestAProxyWhoseSocketCantBeMadeDoesntStart(t *testing.T) {
	p, err := Start(nil, filepath.Join(t.TempDir(), "missing", "p.sock"), nil)
	if err == nil {
		p.Close()
		t.Fatal("started with no socket")
	}
}

func TestTheDiallerRefusesAnAddressItCantRead(t *testing.T) {
	p := &Proxy{}
	if err := p.refuseLoopback("tcp", "no port here", nil); err == nil {
		t.Fatal("an address with no port was let through")
	}
	if err := p.refuseLoopback("tcp", "127.0.0.1:443", nil); err == nil {
		t.Fatal("the machine itself was let through")
	}
	if err := p.refuseLoopback("tcp", "93.184.215.14:443", nil); err != nil {
		t.Fatalf("an outside address: %v", err)
	}
}

func TestATargetIsAHostAndAPort(t *testing.T) {
	for _, bad := range []string{":443", "a b:443", "me@example.com:443", `a\b:443`, "a/b:443", "example.com:0", "example.com:x"} {
		if h, p, err := target(bad, 0); err == nil {
			t.Errorf("target(%q) = %q, %d", bad, h, p)
		}
	}
	if _, _, err := target("example.com", 0); err == nil {
		t.Error("a CONNECT with no port")
	}
	if h, p, err := target("example.com", 80); err != nil || h != "example.com" || p != 80 {
		t.Errorf("a plain request's host: %q %d %v", h, p, err)
	}
}

func TestTheProxyAnswersOnlyAProxysRequests(t *testing.T) {
	r := newRig(t, http.HandlerFunc(hello), "", Rule{"pkg.example.com", 80})
	send := func(req string) (int, string) {
		c, err := net.Dial("tcp", r.addr())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		io.WriteString(c, req)
		resp, err := http.ReadResponse(bufio.NewReader(c), nil)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(body)
	}
	// A server's request, not a proxy's.
	if code, body := send("GET /index HTTP/1.1\r\nHost: pkg.example.com\r\nConnection: close\r\n\r\n"); code != 400 ||
		!strings.Contains(body, "this is a job's proxy") {
		t.Fatalf("a plain server request: %d %q", code, body)
	}
	// A port that isn't one.
	if code, body := send("GET http://pkg.example.com:99999/ HTTP/1.1\r\nHost: pkg.example.com\r\nConnection: close\r\n\r\n"); code != 400 ||
		!strings.Contains(body, "no such port") {
		t.Fatalf("a bad port: %d %q", code, body)
	}
}

// noHijack is a ResponseWriter that can't be taken over; hijackFails is
// one whose takeover fails.
type noHijack struct{ *httptest.ResponseRecorder }

type hijackFails struct{ *httptest.ResponseRecorder }

func (hijackFails) Hijack() (net.Conn, *bufio.ReadWriter, error) { return nil, nil, errors.New("no") }

// hijackTo hands over down, with what the job sent after its CONNECT
// already read.
type hijackTo struct {
	*httptest.ResponseRecorder
	down net.Conn
	sent string
}

func (h hijackTo) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return h.down, bufio.NewReadWriter(bufio.NewReader(strings.NewReader(h.sent)), bufio.NewWriter(h.down)), nil
}

// pipeProxy is a proxy whose every dial gets one end of a pipe; ups are
// the other ends.
func pipeProxy(t *testing.T) (*Proxy, chan net.Conn) {
	t.Helper()
	ups := make(chan net.Conn, 4)
	p, err := start([]Rule{{"api.example.com", 443}}, "", nil, func(context.Context, string, string) (net.Conn, error) {
		a, b := net.Pipe()
		ups <- b
		return a, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	return p, ups
}

func closedEnd(t *testing.T, c net.Conn) bool {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, err := c.Read(make([]byte, 1))
	return err != nil && !strings.Contains(err.Error(), "timeout")
}

func TestATunnelThatCantBeTakenOverIsClosed(t *testing.T) {
	req := httptest.NewRequest(http.MethodConnect, "http://api.example.com:443", nil)
	req.Host = "api.example.com:443"

	p, ups := pipeProxy(t)
	rec := noHijack{httptest.NewRecorder()}
	p.ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("no hijacker: %d", rec.Code)
	}
	if !closedEnd(t, <-ups) {
		t.Fatal("no hijacker: the upstream connection was left open")
	}

	p, ups = pipeProxy(t)
	done := make(chan struct{})
	go func() { p.ServeHTTP(hijackFails{httptest.NewRecorder()}, req); close(done) }()
	if !closedEnd(t, <-ups) {
		t.Fatal("a failed hijack: the upstream connection was left open")
	}
	<-done

	// The job's side gone before the tunnel's answer: the tunnel ends,
	// and nothing the job sent goes up it.
	p, ups = pipeProxy(t)
	down, other := net.Pipe()
	other.Close()
	done = make(chan struct{})
	go func() {
		p.ServeHTTP(hijackTo{httptest.NewRecorder(), down, "sent after the CONNECT"}, req)
		close(done)
	}()
	up := <-ups
	up.SetReadDeadline(time.Now().Add(5 * time.Second))
	if n, _ := up.Read(make([]byte, 64)); n != 0 {
		t.Fatal("what the job sent went up a tunnel it was never told was open")
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		up.Close()
		t.Fatal("a tunnel whose job side is gone didn't end")
	}
}

func TestAClosedProxyTakesNoNewTunnel(t *testing.T) {
	p, err := Start(nil, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	p.Close()
	a, b := net.Pipe()
	defer b.Close()
	if p.track(a) {
		t.Fatal("a closed proxy took a connection")
	}
	if !closedEnd(t, b) {
		t.Fatal("the connection it refused is still open")
	}
}

func TestRulesFromAURLOrARemoteNeedAPort(t *testing.T) {
	for _, bad := range []string{"https://example.com:0", "https://example.com:70000"} {
		if got, ok := URLRule(bad); ok {
			t.Errorf("URLRule(%q) = %v", bad, got)
		}
	}
	for _, bad := range []string{"ftp://example.com/repo", "ssh://example.com:0/r.git", "ssh://example.com:70000/r.git"} {
		if got, ok := RemoteRule(bad); ok {
			t.Errorf("RemoteRule(%q) = %v", bad, got)
		}
	}
}
