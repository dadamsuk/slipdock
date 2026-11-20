package egress

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// Tripwire is one job's fake credentials (#3524): an AWS access key and a
// GitHub token, shaped like real ones, random for each job so that one
// seen names the job. They are written where tools look for credentials in
// the job's own home; nothing real ever has these values, so one of them
// in what the job sends out means something in the job read them and is
// sending them on. The proxy watches for them in all it can see.
//
// Detection, not prevention: the proxy sees a CONNECT's target and
// headers, a plain-HTTP request's line, headers and body, and the bytes a
// job sends through a tunnel; it cannot read inside TLS, so a value sent
// inside an encrypted connection to an allowed host passes unseen.
type Tripwire struct {
	AWSKeyID     string // AKIA + 16
	AWSSecret    string // 40
	GitHubToken  string // ghp_ + 36
	needles      []needle
	longestBytes int
}

// needle is what is looked for: the random part of a value, lower case
// (a hostname's case doesn't survive), and which value it is.
type needle struct {
	what string
	b    []byte
}

const (
	upperAlnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	alnum      = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
)

// NewTripwire makes a job's fake credentials.
func NewTripwire() (*Tripwire, error) {
	id, err := randomFrom(upperAlnum, 16)
	if err != nil {
		return nil, err
	}
	secret, err := randomFrom(alnum, 40)
	if err != nil {
		return nil, err
	}
	gh, err := randomFrom(alnum, 36)
	if err != nil {
		return nil, err
	}
	return newTripwire("AKIA"+id, secret, "ghp_"+gh), nil
}

func newTripwire(keyID, secret, token string) *Tripwire {
	t := &Tripwire{AWSKeyID: keyID, AWSSecret: secret, GitHubToken: token}
	// The random parts: a prefix dropped, or a value cased otherwise,
	// is still the value.
	for _, n := range []needle{
		{"the AWS access key id", []byte(strings.TrimPrefix(keyID, "AKIA"))},
		{"the AWS secret key", []byte(secret)},
		{"the GitHub token", []byte(strings.TrimPrefix(token, "ghp_"))},
	} {
		n.b = bytes.ToLower(n.b)
		t.needles = append(t.needles, n)
		if len(n.b) > t.longestBytes {
			t.longestBytes = len(n.b)
		}
	}
	return t
}

func randomFrom(set string, n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("no randomness for the job's tripwire: %v", err)
	}
	for i := range b {
		b[i] = set[int(b[i])%len(set)]
	}
	return string(b), nil
}

// Files are the fake credential files, by their path under the home.
func (t *Tripwire) Files() map[string]string {
	return map[string]string{
		".aws/credentials": "[default]\naws_access_key_id = " + t.AWSKeyID +
			"\naws_secret_access_key = " + t.AWSSecret + "\n",
		".config/gh/hosts.yml": "github.com:\n    oauth_token: " + t.GitHubToken +
			"\n    user: slipdock-job\n    git_protocol: https\n",
	}
}

// find says which value s holds, or "".
func (t *Tripwire) find(s []byte) string {
	if t == nil || len(s) == 0 {
		return ""
	}
	low := bytes.ToLower(s)
	for _, n := range t.needles {
		if bytes.Contains(low, n.b) {
			return n.what
		}
	}
	return ""
}

// findString is find, also on s with its %-escapes undone.
func (t *Tripwire) findString(s string) string {
	if what := t.find([]byte(s)); what != "" {
		return what
	}
	if u, err := url.QueryUnescape(s); err == nil && u != s {
		return t.find([]byte(u))
	}
	return ""
}

// inRequest is where in r, as far as the proxy can see before it passes
// it on (its line, its target, its headers, a Basic login decoded), one of
// the values is, or "".
func (t *Tripwire) inRequest(r *http.Request) string {
	if t == nil {
		return ""
	}
	if what := t.findString(r.Method + " " + r.RequestURI); what != "" {
		return what + ", in the request line"
	}
	if what := t.findString(r.Host); what != "" {
		return what + ", in the host"
	}
	for name, values := range r.Header {
		for _, v := range values {
			what := t.findString(name + ": " + v)
			if what == "" {
				what = t.inBasic(v)
			}
			if what != "" {
				return what + ", in the " + http.CanonicalHeaderKey(name) + " header"
			}
		}
	}
	return ""
}

// inBasic decodes a Basic login (git over HTTP sends a token as one).
func (t *Tripwire) inBasic(v string) string {
	scheme, cred, ok := strings.Cut(strings.TrimSpace(v), " ")
	if !ok || !strings.EqualFold(scheme, "basic") {
		return ""
	}
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(cred))
	if err != nil {
		return ""
	}
	return t.find(b)
}

// scanner reads through r, looking in what passes for the values, a
// value split across two reads included. Seen, it calls hit once and
// fails the read, so nothing more of it passes.
type scanner struct {
	r     io.Reader
	t     *Tripwire
	where string
	hit   func(what string)
	tail  []byte
	err   error
}

func (t *Tripwire) scan(r io.Reader, where string, hit func(string)) io.Reader {
	if t == nil {
		return r
	}
	return &scanner{r: r, t: t, where: where, hit: hit}
}

// errTripped fails a read that carried one of the job's fake credentials.
var errTripped = fmt.Errorf("slipdock-runner: the job's fake credentials were seen leaving, so the connection was closed")

func (s *scanner) Read(p []byte) (int, error) {
	if s.err != nil {
		return 0, s.err
	}
	n, err := s.r.Read(p)
	if n > 0 {
		window := append(append([]byte(nil), s.tail...), p[:n]...)
		if what := s.t.find(window); what != "" {
			s.err = errTripped
			s.hit(what + ", in " + s.where)
			return 0, s.err
		}
		keep := s.t.longestBytes - 1
		if len(window) > keep {
			window = window[len(window)-keep:]
		}
		s.tail = window
	}
	return n, err
}
