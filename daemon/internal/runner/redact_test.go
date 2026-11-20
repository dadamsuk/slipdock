package runner

import (
	"encoding/base64"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Fake secrets, made at run time from obviously fake parts, so no source
// line holds a whole token's shape.
func fakeTok(parts ...string) string { return strings.Join(parts, "") }

var (
	fakeBody     = strings.Repeat("Fake0", 8)                 // 40 letters and digits
	fakeSlipdock = fakeTok("sd", "r_", fakeBody)              // a runner token's shape
	fakeGitHub   = fakeTok("gh", "p_", fakeBody)              // a classic token
	fakeGitHubS  = fakeTok("gh", "s_", fakeBody)              // an app's installation token
	fakeGitHubFG = fakeTok("github", "_pat_", fakeBody, "_x") // fine-grained
	fakeAnth     = fakeTok("sk", "-ant-", "api03-", fakeBody)
	fakeOpenAI   = fakeTok("sk", "-proj-", fakeBody)
	fakeOpenAI2  = fakeTok("sk", "-", fakeBody)
	fakeAWSID    = fakeTok("AK", "IA", "FAKE0FAKE0FAKE00")
	fakeAWSTemp  = fakeTok("AS", "IA", "FAKE0FAKE0FAKE00")
	fakeAWSKey   = strings.Repeat("Fake0/+", 6)
	// AWS secret keys the generic assignment rule skips: no digit, no letter.
	fakeAWSKeyLetters = strings.Repeat("Fake", 10)
	fakeAWSKeyDigits  = strings.Repeat("0/+9", 10)
	fakeJWT           = fakeTok("ey", "J", fakeBody, ".ey", "J", fakeBody, ".", fakeBody)
)

func TestTheRedactorTakesOutEachShape(t *testing.T) {
	basic := base64.StdEncoding.EncodeToString([]byte("someone:" + fakeBody))
	key := fakeTok("-----BEGIN ", "RSA PRIVATE KEY-----\n", fakeBody, "\n", fakeBody, "\n-----END ", "RSA PRIVATE KEY-----")
	r := newRedactor([]string{"plainliteralvalue"})
	for _, c := range []struct {
		name, in, secret, want string
	}{
		{"this machine's own, as a literal", "key plainliteralvalue here", "plainliteralvalue", "key [redacted] here"},
		{"a Slipdock token", "SLIPDOCK_TOKEN=" + fakeSlipdock, fakeBody, "SLIPDOCK_TOKEN=[redacted]"},
		{"a GitHub token", "push with " + fakeGitHub + " now", fakeBody, "push with [redacted] now"},
		{"a GitHub app token", "token " + fakeGitHubS, fakeBody, "token [redacted]"},
		{"a fine-grained GitHub token", "GH=" + fakeGitHubFG, fakeBody, "GH=[redacted]"},
		{"an Anthropic key", "ANTHROPIC_API_KEY " + fakeAnth, fakeBody, "ANTHROPIC_API_KEY [redacted]"},
		{"an OpenAI project key", "key: " + fakeOpenAI, fakeBody, "key: [redacted]"},
		{"an OpenAI key", "use " + fakeOpenAI2, fakeBody, "use [redacted]"},
		{"an AWS key id", "id " + fakeAWSID + " ok", "FAKE0FAKE0FAKE00", "id [redacted] ok"},
		{"an AWS temporary key id", "id " + fakeAWSTemp, "FAKE0FAKE0FAKE00", "id [redacted]"},
		{"an AWS secret key", "aws_secret_access_key = " + fakeAWSKey, fakeAWSKey, "aws_secret_access_key = [redacted]"},
		{"an AWS secret key of letters only", "aws_secret_access_key=" + fakeAWSKeyLetters, fakeAWSKeyLetters, "aws_secret_access_key=[redacted]"},
		{"an AWS secret key with no letters", "aws_secret_access_key: " + fakeAWSKeyDigits, fakeAWSKeyDigits, "aws_secret_access_key: [redacted]"},
		{"a bearer header", "Authorization: Bearer " + fakeBody, fakeBody, "Authorization: Bearer [redacted]"},
		{"a bare bearer token", "curl -H 'bearer " + fakeBody + "'", fakeBody, "curl -H 'bearer [redacted]'"},
		{"a basic-auth header", "Authorization: Basic " + basic, basic, "Authorization: Basic [redacted]"},
		{"a URL's user and password", "git clone https://someone:" + fakeBody + "@example.com/org/repo.git", fakeBody,
			"git clone https://[redacted]@example.com/org/repo.git"},
		{"a URL with a token as its user", "https://x-access-token:" + fakeGitHubS + "@example.com/o/r", fakeBody,
			"https://[redacted]@example.com/o/r"},
		{"a password setting", `password = "` + fakeBody + `"`, fakeBody, `password = "[redacted]"`},
		{"a private key", "before\n" + key + "\nafter", fakeBody, "before\n[redacted]\nafter"},
		{"a JWT", "jwt " + fakeJWT, fakeBody, "jwt [redacted]"},
	} {
		got := string(r.redact([]byte(c.in)).bytes())
		if strings.Contains(got, c.secret) || got != c.want {
			t.Errorf("%s: %q redacted to %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestTheRedactorLeavesOrdinaryTextAlone(t *testing.T) {
	r := newRedactor(nil)
	for _, in := range []string{
		"commit 3f786850e387550fdab836ed7e6dc881de23001b merged",
		"job 123e4567-e89b-12d3-a456-426614174000 started",
		"Bearer authentication is used by the API",
		"token = newTokenForUser2(id)",
		"the password: is not set",
		"see https://example.com/path/to/thing and ssh://git@example.com/repo",
		"sk-short and ghp_short and sdm_short",
		"internal/thing/file.go:12: ok",
	} {
		if got := string(r.redact([]byte(in)).bytes()); got != in {
			t.Errorf("%q redacted to %q", in, got)
		}
	}
}

// A secret cut by the start of the tail leaves nothing recognisable of
// itself, wherever the cut falls in it.
func TestATailCutThroughASecretLeavesNoneOfIt(t *testing.T) {
	r := newRedactor(nil)
	for _, c := range []struct {
		name, line, secret string
		n                  int
		// secrets fills the rest with lines of secrets, which shrink as
		// they are redacted, so the whole read is kept, its start too.
		secrets bool
	}{
		{"a token on its line", "export GH=" + fakeGitHub, fakeBody, 200, false},
		{"a bearer header", "Authorization: Bearer " + fakeBody, fakeBody, 200, false},
		{"a token in one long line", strings.Repeat("y ", 10) + fakeGitHub, fakeBody, 200, false},
		{"a token before lines of secrets", "export GH=" + fakeGitHub, fakeBody, 2000, true},
		{"a bearer header before lines of secrets", "Authorization: Bearer " + fakeBody, fakeBody, 2000, true},
	} {
		n := c.n
		for k := 1; k < len(c.line); k++ {
			// The read starts n+tailMargin bytes from the end: put the
			// cut k bytes into the line.
			size := n + tailMargin - (len(c.line) - k)
			after := strings.Repeat("z", size)
			if c.name != "a token in one long line" {
				after = "\n" + after[1:]
			}
			if c.secrets {
				lines := strings.Repeat(fakeGitHub+"\n", (size-100)/(len(fakeGitHub)+1))
				after = "\n" + lines + strings.Repeat("z", size-1-len(lines))
			}
			path := filepath.Join(t.TempDir(), "job.log")
			if err := os.WriteFile(path, []byte("head "+c.line+after), 0o600); err != nil {
				t.Fatal(err)
			}
			got := string(r.tail(path, n).bytes())
			if len(got) > n {
				t.Fatalf("%s cut at %d: %d bytes, want at most %d", c.name, k, len(got), n)
			}
			if leaksPart(got, c.secret) {
				t.Fatalf("%s cut at %d (%q): a part of the secret is left:\n%q", c.name, k, c.line[k:], got)
			}
			// Before the margin is dropped, too.
			if left := string(r.scrub(dropPartial([]byte(c.line[k:]+after)), true)); leaksPart(left, c.secret) {
				t.Fatalf("%s cut at %d: a part of the secret is left in the margin:\n%q", c.name, k, left)
			}
		}
	}
}

// leaksPart is whether s holds 8 or more bytes of secret in a row.
func leaksPart(s, secret string) bool {
	for i := 0; i+8 <= len(secret); i++ {
		if strings.Contains(s, secret[i:i+8]) {
			return true
		}
	}
	return false
}

func TestATailCutThroughAPrivateKeyLeavesNoneOfIt(t *testing.T) {
	r := newRedactor(nil)
	key := fakeTok("-----BEGIN ", "PRIVATE KEY-----\n", fakeBody, "\n", fakeBody, "\n-----END ", "PRIVATE KEY-----\n")
	path := filepath.Join(t.TempDir(), "job.log")
	cut := len("-----BEGIN PRIVATE KEY-----\n") + 3
	pad := strings.Repeat("z", 100+tailMargin-(len(key)-cut)-1) + "\n"
	if err := os.WriteFile(path, []byte(key+pad), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := string(r.scrub([]byte(key[cut:]+pad), true)); leaksPart(got, fakeBody) {
		t.Fatalf("a key whose start was cut off: %q", got)
	}
	// The end of the key is still unwritten: it goes to the end.
	if got := string(r.redact([]byte("x\n" + key[:40])).bytes()); got != "x\n[redacted]" {
		t.Fatalf("a key not yet ended: %q", got)
	}
}

func TestASmallLogIsSentWholeRedacted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "job.log")
	if err := os.WriteFile(path, []byte("first line\nkey "+fakeGitHub+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := string(newRedactor(nil).tail(path, 8000).bytes()); got != "first line\nkey [redacted]\n" {
		t.Fatalf("tail = %q", got)
	}
	if got := newRedactor(nil).tail(filepath.Join(t.TempDir(), "none"), 10).bytes(); len(got) != 0 {
		t.Fatalf("no log: %q", got)
	}
}

// A job's log and transcript with secrets in them: none reaches the
// server, in a heartbeat, the finish, the requeue's body or its reason, or
// the transcript.
func TestNothingAJobUploadsCarriesASecret(t *testing.T) {
	literal := "plain-env-literal-value"
	say := strings.Join([]string{
		"Authorization: Bearer " + fakeBody,
		"push " + fakeGitHub + " and " + fakeAnth,
		"aws_secret_access_key=" + fakeAWSKey,
		"https://someone:" + fakeBody + "@example.com/repo.git",
		"the literal " + literal + " and the machine key sdm_test_key",
		"You've hit your weekly limit " + fakeOpenAI + " · resets 11:59pm",
	}, "\n")
	secrets := []string{fakeBody, fakeAWSKey, literal, "sdm_test_key", "FAKE0FAKE0FAKE00"}
	for _, c := range []struct {
		name, exit, status string
	}{
		{"finish", "0", ""},
		{"requeue", "1", "requeue"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t, Config{})
			r.w.Holds = NewHolds()
			r.w.Local.Agents["claude"] = self("say-wait")
			r.w.Getenv = func(k string) string {
				if k == "SLIPDOCK_TOKEN" {
					return literal
				}
				return ""
			}
			t.Setenv("HELPER_SAY", say)
			t.Setenv("HELPER_EXIT", c.exit)
			t.Setenv("HELPER_TRANSCRIPT", filepath.Join(r.w.Home, ".claude", "projects", "p", "s.jsonl"))
			t.Setenv("HELPER_TRANSCRIPT_BODY", `{"u":"https://slipdock.example.com/boards/3/cards/7","t":"`+
				strings.ReplaceAll(say, "\n", `\n`)+`"}`+"\n")
			f := r.runJob(fakeJob{id: 610, kind: "claude", card: 7, prompt: "x"})
			if f.status != c.status {
				t.Fatalf("finish = %+v, want status %q", f, c.status)
			}
			r.srv.mu.Lock()
			beats, tx := r.srv.beats[610], r.srv.transcript[610]
			r.srv.mu.Unlock()
			if len(beats) == 0 || len(tx) == 0 {
				t.Fatalf("want heartbeats and a transcript: %d beats, transcript %q", len(beats), tx)
			}
			sent := map[string]string{"finish body": f.body, "query": f.query.Encode(), "transcript": strings.Join(tx, "\n")}
			for i, b := range beats {
				sent["heartbeat "+string(rune('0'+i%10))] = b
			}
			if !strings.Contains(f.body, "Authorization: Bearer [redacted]") || !strings.Contains(sent["transcript"], "[redacted]") {
				t.Fatalf("the log isn't there, redacted: body %q, transcript %q", f.body, sent["transcript"])
			}
			for where, body := range sent {
				for _, s := range secrets {
					if strings.Contains(body, s) {
						t.Errorf("the %s carries %q:\n%s", where, s, body)
					}
				}
			}
		})
	}
}

// The client's uploads take only scrubbed text, and only redact.go makes
// it, so nothing reaches the server without going through the redactor.
func TestOnlyTheRedactorMakesScrubbed(t *testing.T) {
	want := reflect.TypeOf(scrubbed{})
	byteSlice := reflect.TypeOf([]byte(nil))
	for name, fn := range map[string]any{
		"Heartbeat": (*Client).Heartbeat, "Transcript": (*Client).Transcript, "Finish": (*Client).Finish,
		"Requeue": (*Client).Requeue, "Tripped": (*Client).Tripped,
	} {
		ft, found := reflect.TypeOf(fn), false
		for i := 0; i < ft.NumIn(); i++ {
			found = found || ft.In(i) == want
			if ft.In(i) == byteSlice {
				t.Errorf("Client.%s takes a []byte: its body must be scrubbed", name)
			}
		}
		if !found {
			t.Errorf("Client.%s takes no scrubbed body", name)
		}
	}
	fset := token.NewFileSet()
	files, _ := filepath.Glob("*.go")
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") || path == "redact.go" {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.CompositeLit:
				if id, ok := n.Type.(*ast.Ident); ok && id.Name == "scrubbed" && len(n.Elts) > 0 {
					t.Errorf("%s: scrubbed made outside redact.go", fset.Position(n.Pos()))
				}
			case *ast.Ident:
				if n.Name == "redactedBytes" {
					t.Errorf("%s: scrubbed's text set outside redact.go", fset.Position(n.Pos()))
				}
			}
			return true
		})
	}
}
