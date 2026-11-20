package egress

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestARuleIsAHostAndAPort(t *testing.T) {
	for in, want := range map[string]Rule{
		"registry.npmjs.org":   {"registry.npmjs.org", 443},
		"Example.COM.":         {"example.com", 443},
		"example.com:8443":     {"example.com", 8443},
		"*.example.com":        {"*.example.com", 443},
		"localhost:5432":       {"localhost", 5432},
		"127.0.0.1:6379":       {"127.0.0.1", 6379},
		" git.example.com:22 ": {"git.example.com", 22},
	} {
		got, err := ParseRule(in)
		if err != nil || got != want {
			t.Errorf("ParseRule(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "*", "*.", "https://example.com", "example.com/path", "example.com:0", "example.com:65536",
		"example.com:+1", "example.com:http", "user@example.com", "ex ample.com", "-x.example.com", "localhost", "127.0.0.1",
		"[::1]:22", "a.*.example.com", strings.Repeat("a", 64) + ".example.com"} {
		if r, err := ParseRule(bad); err == nil {
			t.Errorf("ParseRule(%q) = %v, want an error", bad, r)
		}
	}
	if r, _ := ParseRule("localhost:5432"); !r.Loopback() {
		t.Error("localhost:5432 isn't a port of the machine")
	}
	if r, _ := ParseRule("example.com:5432"); r.Loopback() {
		t.Error("example.com is the machine")
	}
}

func TestARuleAllowsOnlyItsHostAndPort(t *testing.T) {
	exact, wild := Rule{"example.com", 443}, Rule{"*.example.com", 443}
	for _, c := range []struct {
		r    Rule
		host string
		port int
		want bool
	}{
		{exact, "example.com", 443, true}, {exact, "EXAMPLE.com.", 443, true},
		{exact, "example.com", 80, false}, {exact, "api.example.com", 443, false},
		{exact, "example.com.evil.test", 443, false}, {exact, "evilexample.com", 443, false},
		{wild, "api.example.com", 443, true}, {wild, "a.b.example.com", 443, true},
		{wild, "example.com", 443, false}, {wild, "evilexample.com", 443, false}, {wild, ".example.com", 443, false},
		{wild, "api.example.com", 22, false},
	} {
		if got := c.r.Allows(c.host, c.port); got != c.want {
			t.Errorf("%v allows %s:%d = %v, want %v", c.r, c.host, c.port, got, c.want)
		}
	}
}

func TestTheJobsOwnHostsAreFoundFromItsAgentServerAndRemote(t *testing.T) {
	if got := AgentRules("claude"); len(got) == 0 || got[0] != (Rule{"api.anthropic.com", 443}) {
		t.Errorf("claude: %v", got)
	}
	if got := AgentRules("codex"); len(got) == 0 || got[0] != (Rule{"api.openai.com", 443}) {
		t.Errorf("codex: %v", got)
	}
	if got := AgentRules("mine"); got != nil {
		t.Errorf("a custom agent: %v", got)
	}
	for in, want := range map[string]Rule{
		"https://app.example.com":        {"app.example.com", 443},
		"http://localhost:4000/":         {"localhost", 4000},
		"https://Board.Example.com:8443": {"board.example.com", 8443},
	} {
		if got, ok := URLRule(in); !ok || got != want {
			t.Errorf("URLRule(%q) = %v, %v", in, got, ok)
		}
	}
	for _, bad := range []string{"", "ftp://example.com", "https://", "https://example.com:0x1"} {
		if got, ok := URLRule(bad); ok {
			t.Errorf("URLRule(%q) = %v", bad, got)
		}
	}
	for in, want := range map[string]Rule{
		"https://github.com/me/repo.git":   {"github.com", 443},
		"http://git.example.com/repo":      {"git.example.com", 80},
		"ssh://git.example.com:2222/r.git": {"git.example.com", 2222},
		"ssh://git.example.com/r.git":      {"git.example.com", 22},
		"git@example.com:me/repo.git":      {"example.com", 22},
		"GitHub.com:me/repo.git":           {"github.com", 22},
		"git://git.example.com/repo":       {"git.example.com", 9418},
		"  https://example.com/r\n":        {"example.com", 443},
	} {
		if got, ok := RemoteRule(in); !ok || got != want {
			t.Errorf("RemoteRule(%q) = %v, %v; want %v", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "/srv/git/repo.git", "./repo", "file:///srv/repo", "ext::sh -c x", "https://"} {
		if got, ok := RemoteRule(bad); ok {
			t.Errorf("RemoteRule(%q) = %v", bad, got)
		}
	}
}

// rig is a proxy whose allowed hosts all reach one test server.
type rig struct {
	p    *Proxy
	logs *lines
	up   string // the test server's address
}

type lines struct {
	mu sync.Mutex
	l  []string
}

func (l *lines) add(s string) { l.mu.Lock(); l.l = append(l.l, s); l.mu.Unlock() }
func (l *lines) all() string  { l.mu.Lock(); defer l.mu.Unlock(); return strings.Join(l.l, "\n") }

func newRig(t *testing.T, h http.Handler, socket string, rules ...Rule) *rig {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	logs := &lines{}
	p, err := Start(rules, socket, logs.add)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	up := strings.TrimPrefix(srv.URL, "http://")
	p.dial = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, up) // every allowed host is the test server
	}
	return &rig{p: p, logs: logs, up: up}
}

func (r *rig) addr() string { return fmt.Sprintf("127.0.0.1:%d", r.p.Port()) }

func (r *rig) client() *http.Client {
	u, _ := url.Parse("http://" + r.addr())
	return &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(u)}, Timeout: 10 * time.Second}
}

// connect sends a CONNECT for target, and returns the status and the
// connection.
func connect(t *testing.T, proxy, target string) (int, net.Conn, *bufio.Reader) {
	t.Helper()
	c, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, c, br
}

func hello(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "hello %s host=%s", r.URL.Path, r.Host)
}

func TestTheProxyTunnelsOnlyToAnAllowedHost(t *testing.T) {
	r := newRig(t, http.HandlerFunc(hello), "", Rule{"api.example.com", 443}, Rule{"*.git.example.com", 22})

	code, c, br := connect(t, r.addr(), "api.example.com:443")
	if code != http.StatusOK {
		t.Fatalf("an allowed host: %d", code)
	}
	fmt.Fprintf(c, "GET /through HTTP/1.1\r\nHost: api.example.com\r\nConnection: close\r\n\r\n")
	body, _ := io.ReadAll(br)
	if !strings.Contains(string(body), "hello /through") {
		t.Fatalf("through the tunnel: %q", body)
	}
	if code, _, _ := connect(t, r.addr(), "API.Example.com.:443"); code != http.StatusOK {
		t.Fatalf("case and a trailing dot: %d", code)
	}
	if code, _, _ := connect(t, r.addr(), "x.git.example.com:22"); code != http.StatusOK {
		t.Fatalf("a name under a wildcard: %d", code)
	}

	for _, denied := range []string{"evil.example.net:443", "api.example.com:80", "api.example.com:22", "example.com:443",
		"api.example.com.evil.test:443", "192.0.2.1:443", "git.example.com:22", "127.0.0.1:" + strings.Split(r.up, ":")[1]} {
		if code, _, _ := connect(t, r.addr(), denied); code != http.StatusForbidden {
			t.Errorf("%s: %d, want 403", denied, code)
		}
	}
	if code, _, _ := connect(t, r.addr(), "api.example.com"); code != http.StatusBadRequest {
		t.Errorf("a CONNECT with no port: %d", code)
	}
	if code, _, _ := connect(t, r.addr(), "api.example.com:99999"); code != http.StatusBadRequest {
		t.Errorf("a CONNECT to no such port: %d", code)
	}
	logs := r.logs.all()
	if !strings.Contains(logs, "refused a connection to evil.example.net:443, which isn't on the job's allowlist") {
		t.Errorf("the log doesn't say what was refused:\n%s", logs)
	}
	if strings.Contains(logs, "api.example.com:443") {
		t.Errorf("an allowed host was logged as refused:\n%s", logs)
	}
	connect(t, r.addr(), "evil.example.net:443")
	if n := strings.Count(r.logs.all(), "evil.example.net:443"); n != 1 {
		t.Errorf("a host refused twice is logged %d times, want once", n)
	}
}

func TestTheProxyForwardsPlainHTTPOnlyToAnAllowedHost(t *testing.T) {
	r := newRig(t, http.HandlerFunc(hello), "", Rule{"pkg.example.com", 80})
	resp, err := r.client().Get("http://pkg.example.com/index")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "hello /index host=pkg.example.com:80") {
		t.Fatalf("an allowed plain request: %d %q", resp.StatusCode, body)
	}
	// The upstream sees the host allowed, never another the job put in a header.
	c, err := net.Dial("tcp", r.addr())
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(c, "GET http://pkg.example.com/x HTTP/1.1\r\nHost: evil.example.net\r\nConnection: close\r\n\r\n")
	body, _ = io.ReadAll(c)
	c.Close()
	if !strings.Contains(string(body), "host=pkg.example.com:80") {
		t.Fatalf("a Host header passed through: %q", body)
	}
	for _, denied := range []string{"http://evil.example.net/", "http://pkg.example.com:8080/", "http://127.0.0.1/"} {
		resp, err := r.client().Get(denied)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusForbidden {
			t.Errorf("%s: %d, want 403", denied, resp.StatusCode)
		}
	}
	if !strings.Contains(r.logs.all(), "evil.example.net:80") {
		t.Errorf("the refusal isn't logged:\n%s", r.logs.all())
	}
	// A request that isn't for a proxy.
	resp, err = http.Get("http://" + r.addr() + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("a request for the proxy itself: %d", resp.StatusCode)
	}
}

func TestAnAllowedNameThatIsTheMachineIsRefused(t *testing.T) {
	logs := &lines{}
	p, err := Start([]Rule{{"localhost", 80}, {"127.0.0.2", 8443}}, "", logs.add)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	for _, addr := range []string{"127.0.0.1:443", "[::1]:443", "0.0.0.0:443"} {
		if err := p.refuseLoopback("tcp", addr, nil); err == nil {
			t.Errorf("%s: dialled", addr)
		}
	}
	if err := p.refuseLoopback("tcp", "93.184.216.34:443", nil); err != nil {
		t.Errorf("a host elsewhere: %v", err)
	}
	if err := p.refuseLoopback("tcp", "127.0.0.1:80", nil); err != nil {
		t.Errorf("a port of the machine the rules name: %v", err)
	}
	// The real dial, through the proxy: a name the rules allow that is
	// the machine, but not a port of it they name.
	addr := fmt.Sprintf("127.0.0.1:%d", p.Port())
	if code, _, _ := connect(t, addr, "127.0.0.2:8443"); code != http.StatusBadGateway {
		t.Errorf("an allowed name that is the machine: %d, want 502", code)
	}
	if code, _, _ := connect(t, addr, "localhost:"+strconv.Itoa(p.Port())); code != http.StatusForbidden {
		t.Errorf("the proxy's own port: %d", code)
	}
}

func TestClosingTheProxyEndsItsTunnels(t *testing.T) {
	hold := make(chan struct{})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			<-hold
			c.Close()
		}
	}()
	defer close(hold)
	p, err := Start([]Rule{{"api.example.com", 443}}, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	p.dial = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, ln.Addr().String())
	}
	code, c, _ := connect(t, fmt.Sprintf("127.0.0.1:%d", p.Port()), "api.example.com:443")
	if code != 200 {
		t.Fatal(code)
	}
	p.Close()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil || strings.Contains(err.Error(), "timeout") {
		t.Fatalf("the tunnel is still open after Close: %v", err)
	}
	if _, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", p.Port()), time.Second); err == nil {
		t.Fatal("the proxy still listens")
	}
}

func TestTheProxyAlsoListensOnItsSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix sockets: Linux and macOS")
	}
	dir, err := os.MkdirTemp("", "egress")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "p.sock")
	r := newRig(t, http.HandlerFunc(hello), sock, Rule{"api.example.com", 443})
	if fi, err := os.Stat(sock); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the socket: %v %v", fi, err)
	}
	for target, want := range map[string]string{"api.example.com:443": "200", "evil.example.net:443": "403"} {
		c, err := net.Dial("unix", sock)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
		line, _ := bufio.NewReader(c).ReadString('\n')
		c.Close()
		if !strings.Contains(line, " "+want+" ") {
			t.Errorf("%s over the socket: %q", target, line)
		}
	}
	_ = r
}

func TestConnectIsSshsWayThroughTheProxy(t *testing.T) {
	r := newRig(t, http.HandlerFunc(hello), "", Rule{"git.example.com", 22})
	var out bytes.Buffer
	in := strings.NewReader("GET /ssh HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	if err := Connect(r.addr(), "git.example.com", "22", in, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "hello /ssh") {
		t.Fatalf("through connect: %q", out.String())
	}
	var errs bytes.Buffer
	if code := Main([]string{"connect", r.addr(), "evil.example.net", "22"}, strings.NewReader(""), &out, &errs); code != 1 ||
		!strings.Contains(errs.String(), "refused by the job's network allowlist") {
		t.Fatalf("a refused host: %d %q", code, errs.String())
	}
	for _, bad := range [][]string{nil, {"connect", "x"}, {"what"}, {"forward"}, {"forward", "--listen"},
		{"forward", "--listen", "127.0.0.1:0", "--", "true"}, {"forward", "--to", "s", "--listen", "127.0.0.1:0"}, {"forward", "-x"}} {
		errs.Reset()
		if code := Main(bad, nil, &out, &errs); code != 2 {
			t.Errorf("%q: %d %s", bad, code, errs.String())
		}
	}
}

func TestTheJobsEnvironmentNamesTheProxy(t *testing.T) {
	env := strings.Join(Env("127.0.0.1:4100", "/usr/local/libexec/slipdock-egress"), "\n")
	for _, want := range []string{"HTTPS_PROXY=http://127.0.0.1:4100", "https_proxy=http://127.0.0.1:4100", "HTTP_PROXY=http://127.0.0.1:4100",
		"http_proxy=http://127.0.0.1:4100", "ALL_PROXY=http://127.0.0.1:4100", "NO_PROXY=localhost,127.0.0.1,::1",
		`GIT_SSH_COMMAND=ssh -o ProxyCommand="/usr/local/libexec/slipdock-egress egress connect 127.0.0.1:4100 %h %p"`} {
		if !strings.Contains(env, want+"\n") && !strings.HasSuffix(env, want) {
			t.Errorf("no %s in:\n%s", want, env)
		}
	}
	if strings.Contains(strings.Join(Env("127.0.0.1:4100", ""), "\n"), "GIT_SSH_COMMAND") {
		t.Error("git's ssh is sent through a command there isn't")
	}
}

// TestMain doubles as a job's program behind forward: helper-connect
// PROXY TARGET exits 0 when the proxy lets it through, 3 when it refuses.
func TestMain(m *testing.M) {
	if len(os.Args) == 4 && os.Args[1] == "helper-connect" {
		err := Connect(os.Args[2], strings.Split(os.Args[3], ":")[0], strings.Split(os.Args[3], ":")[1], strings.NewReader(""), io.Discard)
		switch {
		case err == nil:
			os.Exit(0)
		case strings.Contains(err.Error(), ErrDenied.Error()):
			os.Exit(3)
		}
		os.Exit(1)
	}
	os.Exit(m.Run())
}

func TestForwardCarriesTheJobsConnectionsToTheProxysSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix sockets: Linux and macOS")
	}
	dir, err := os.MkdirTemp("", "egress")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "p.sock")
	newRig(t, http.HandlerFunc(hello), sock, Rule{"api.example.com", 443})
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listen := l.Addr().String()
	l.Close()
	var errs bytes.Buffer
	run := func(target string) int {
		return Main([]string{"forward", "--listen", listen, "--to", sock, "--", os.Args[0], "helper-connect", listen, target},
			nil, io.Discard, &errs)
	}
	if code := run("api.example.com:443"); code != 0 {
		t.Fatalf("an allowed host through forward: exit %d %s", code, errs.String())
	}
	if code := run("evil.example.net:443"); code != 3 {
		t.Fatalf("a refused host through forward: exit %d %s", code, errs.String())
	}
	// The program's own exit status is forward's.
	if code := Main([]string{"forward", "--listen", listen, "--to", sock, "--", "/bin/sh", "-c", "exit 7"}, nil, io.Discard, &errs); code != 7 {
		t.Fatalf("exit %d, want 7", code)
	}
	// A port it can't take: the job isn't run.
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	errs.Reset()
	if code := Main([]string{"forward", "--listen", busy.Addr().String(), "--to", sock, "--", "/bin/sh", "-c", "exit 0"}, nil, io.Discard, &errs); code != 126 ||
		!strings.Contains(errs.String(), "the job was not run") {
		t.Fatalf("a busy port: exit %d %s", code, errs.String())
	}
}
