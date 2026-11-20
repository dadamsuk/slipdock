package runner

import (
	"bytes"
	"io"
	"os"
	"regexp"
	"unicode/utf8"
)

// The one redactor for everything a job uploads: its transcript, and the
// tail of its log sent with each heartbeat and with its finish. It takes
// out this machine's own keys and tokens (as literal strings), then the
// shapes of common secrets, the same shapes the server's transcript scrub
// takes out (lib/slipdock/runners/transcript.ex), so what the server stores
// never depends on the server alone.

const redacted = "[redacted]"

// scrubbed is text a redactor has been over: the only kind the client's
// uploads take. Made only in this file (TestOnlyTheRedactorMakesScrubbed).
type scrubbed struct{ redactedBytes []byte }

// bytes is the text, for the request body.
func (s scrubbed) bytes() []byte { return s.redactedBytes }

// redactor is one job's: the literal secrets of the machine and the job,
// longest first, and the shapes every redactor takes out.
type redactor struct {
	secrets []string
}

func newRedactor(secrets ...[]string) *redactor {
	var all []string
	seen := map[string]bool{}
	for _, list := range secrets {
		for _, s := range list {
			if len(s) >= 8 && !seen[s] {
				seen[s] = true
				all = append(all, s)
			}
		}
	}
	return &redactor{secrets: longestFirst(all)}
}

// Generic shapes only, never a list of real values. Each is long enough
// that a commit sha, a UUID or ordinary words don't match.
var secretShapes = []*regexp.Regexp{
	regexp.MustCompile(`(?s)-----BEGIN[A-Z ]*PRIVATE KEY-----.*?(?:-----END[A-Z ]*PRIVATE KEY-----|\z)`),
	// Slipdock's own: sdm_ machine keys, sdr_ runner tokens, sde_, sdd_,
	// sdc_, sdh_ and whatever comes next under the same prefix.
	regexp.MustCompile(`\bsd[a-z]_[A-Za-z0-9_-]{20,}`),
	regexp.MustCompile(`\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b`),
	regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{30,}`),
	regexp.MustCompile(`\bgithub_pat_[A-Za-z0-9_]{30,}`),
	regexp.MustCompile(`\bglpat-[A-Za-z0-9_-]{20,}`),
	regexp.MustCompile(`\bxox[abposr]-[A-Za-z0-9-]{10,}`),
	// sk-ant- (Anthropic), sk-proj- and plain sk- (OpenAI).
	regexp.MustCompile(`\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}`),
	regexp.MustCompile(`\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}`),
	regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}`),
	regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`),
}

var (
	// keyName = value, and Bearer/Basic credentials: the name stays and a
	// value that looks made up (letters and digits) goes.
	assignment = regexp.MustCompile(`(?i)((?:(?:Bearer|Basic)\s+)|(?:(?:password|passwd|secret|api[_-]?key|access[_-]?key|token)[A-Za-z_]*\\?["']?\s*[:=]\s*\\?["']?))([A-Za-z0-9_+/=.~-]{12,})`)
	// An AWS secret key named as one, whatever it holds.
	awsSecret = regexp.MustCompile(`(?i)(aws_secret_access_key\\?["']?\s*[:=]\s*\\?["']?)[A-Za-z0-9/+=]{20,}`)
	// A URL's user and password: the scheme and host stay.
	userinfo = regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@"'<>]+:[^/\s@"'<>]+@`)
	hasDigit = regexp.MustCompile(`[0-9]`)
	hasAlpha = regexp.MustCompile(`[A-Za-z]`)
	// The end of a private key whose start was cut off.
	keyEnd   = regexp.MustCompile(`-----END[A-Z ]*PRIVATE KEY-----`)
	keyBegin = regexp.MustCompile(`-----BEGIN[A-Z ]*PRIVATE KEY-----`)
)

// redact is data with the secrets taken out.
func (r *redactor) redact(data []byte) scrubbed {
	return scrubbed{r.scrub(data, false)}
}

// text is redact for a message the daemon wrote itself.
func (r *redactor) text(s string) scrubbed {
	return r.redact([]byte(s))
}

// scrub takes the secrets out of data; cut says data starts part way
// through what was written, so it may begin inside a private key.
func (r *redactor) scrub(data []byte, cut bool) []byte {
	if len(data) == 0 {
		return data
	}
	out := append([]byte(nil), data...)
	if r != nil {
		for _, s := range r.secrets {
			out = bytes.ReplaceAll(out, []byte(s), []byte(redacted))
		}
	}
	if cut {
		if end := keyEnd.FindIndex(out); end != nil {
			if begin := keyBegin.FindIndex(out); begin == nil || begin[0] > end[0] {
				out = append([]byte(redacted), out[end[1]:]...)
			}
		}
	}
	for _, re := range secretShapes {
		out = re.ReplaceAll(out, []byte(redacted))
	}
	out = awsSecret.ReplaceAll(out, []byte("${1}"+redacted))
	out = replaceValues(out)
	out = userinfo.ReplaceAll(out, []byte("${1}"+redacted+"@"))
	return out
}

// replaceValues is assignment's replacement: a value followed by "(" is a
// call, not a secret, and one without both a letter and a digit is a word.
func replaceValues(data []byte) []byte {
	var out bytes.Buffer
	last := 0
	for _, m := range assignment.FindAllSubmatchIndex(data, -1) {
		value := data[m[4]:m[5]]
		if m[5] < len(data) && data[m[5]] == '(' {
			continue
		}
		if !hasDigit.Match(value) || !hasAlpha.Match(value) {
			continue
		}
		out.Write(data[last:m[4]])
		out.WriteString(redacted)
		last = m[5]
	}
	if last == 0 {
		return data
	}
	out.Write(data[last:])
	return out.Bytes()
}

// tailMargin is how much more than the tail is read and redacted, so a
// secret whose name ("Bearer", "password=") sits just before the tail is
// still recognised; the margin is then dropped.
const tailMargin = 4096

// tail is the last n bytes of the file at path, redacted: the only way a
// job's log is read for upload. Read from part way through, its first
// (partial) line is dropped, so a secret cut in half leaves nothing of it.
func (r *redactor) tail(path string, n int) scrubbed {
	f, err := os.Open(path)
	if err != nil {
		return scrubbed{}
	}
	defer f.Close()
	cut := false
	if fi, err := f.Stat(); err == nil && fi.Size() > int64(n+tailMargin) {
		if _, err := f.Seek(-int64(n+tailMargin), io.SeekEnd); err != nil {
			return scrubbed{}
		}
		cut = true
	}
	data, _ := io.ReadAll(f)
	if cut {
		data = dropPartial(data)
	}
	out := r.scrub(data, cut)
	if len(out) > n {
		out = out[len(out)-n:]
		for len(out) > 0 && !utf8.RuneStart(out[0]) {
			out = out[1:]
		}
	}
	return scrubbed{out}
}

// dropPartial drops what is left of the line the read started in: up to
// and including the first newline, or, in one long line, the run of
// token characters it starts with.
func dropPartial(data []byte) []byte {
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		return data[i+1:]
	}
	i := 0
	for i < len(data) && isTokenByte(data[i]) {
		i++
	}
	return data[i:]
}

func isTokenByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || bytes.IndexByte([]byte("_+/=.~-"), c) >= 0
}
