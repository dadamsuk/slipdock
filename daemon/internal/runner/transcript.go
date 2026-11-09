package runner

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// The live log (#1870), as the shell runner sends it: the job's Claude Code
// transcript, whole lines from where the server is, each line over lineMax
// replaced by a line saying how long it was, each send at most sendMax,
// and this machine's Slipdock keys and tokens taken out.
const (
	sendMax = 512 * 1024
	lineMax = 32 * 1024
)

// transcript is one job's live log.
type transcript struct {
	root    string    // where Claude Code keeps its transcripts
	cardURL string    // a job's transcript mentions its card's link
	started time.Time // and was written since the job started
	path    string    // found
	lines   int       // the lines the server holds
	done    bool      // the server's log is full, or there is none to send
	secrets []string
}

// find sets path to the newest .jsonl in root or one folder below it,
// written since the job started, that mentions the card's link. Kept once found.
func (t *transcript) find() bool {
	if t.path != "" {
		return true
	}
	if t.cardURL == "" || t.root == "" {
		return false
	}
	var found []string
	for _, pattern := range []string{"*.jsonl", filepath.Join("*", "*.jsonl")} {
		m, _ := filepath.Glob(filepath.Join(t.root, pattern))
		found = append(found, m...)
	}
	type file struct {
		path string
		mod  time.Time
	}
	var fresh []file
	for _, p := range found {
		if fi, err := os.Stat(p); err == nil && !fi.ModTime().Before(t.started) {
			fresh = append(fresh, file{p, fi.ModTime()})
		}
	}
	sort.Slice(fresh, func(i, j int) bool { return fresh[i].mod.After(fresh[j].mod) })
	for _, f := range fresh {
		if data, err := os.ReadFile(f.path); err == nil && bytes.Contains(data, []byte(t.cardURL)) {
			t.path = f.path
			return true
		}
	}
	return false
}

// next is the send from line t.lines: whole lines only (one still being
// written waits), cut and scrubbed, at most sendMax. Empty when caught up.
func (t *transcript) next() []byte {
	data, err := os.ReadFile(t.path)
	if err != nil {
		return nil
	}
	if i := bytes.LastIndexByte(data, '\n'); i >= 0 {
		data = data[:i+1]
	} else {
		return nil
	}
	lines := bytes.SplitAfter(data, []byte("\n"))
	if len(lines) > 0 && len(lines[len(lines)-1]) == 0 {
		lines = lines[:len(lines)-1]
	}
	if t.lines >= len(lines) {
		return nil
	}
	var out bytes.Buffer
	for i, line := range lines[t.lines:] {
		body := bytes.TrimRight(line, "\r\n")
		if len(body) > lineMax {
			body = []byte(fmt.Sprintf(`{"type":"slipdock_cut","bytes":%d,"limit":%d}`, len(body), lineMax))
		}
		if i > 0 && out.Len()+len(body)+1 > sendMax {
			break
		}
		out.Write(body)
		out.WriteByte('\n')
	}
	return scrub(out.Bytes(), t.secrets)
}

// scrub takes each secret out of data.
func scrub(data []byte, secrets []string) []byte {
	for _, s := range secrets {
		if len(s) >= 8 {
			data = bytes.ReplaceAll(data, []byte(s), []byte("[redacted]"))
		}
	}
	return data
}

var tokenShape = regexp.MustCompile(`^[A-Za-z0-9_.~+/=-]{8,}$`)

// machineSecrets are the keys and tokens on this machine a transcript must
// never carry: the machine key, $SLIPDOCK_TOKEN, and the slipdock CLI's
// saved tokens (~/.config/slipdock, and under $XDG_CONFIG_HOME). Read again
// for each job, since a person may sign the CLI in between.
func machineSecrets(key, home string, getenv func(string) string) []string {
	secrets := []string{key, getenv("SLIPDOCK_TOKEN")}
	dirs := []string{filepath.Join(home, ".config", "slipdock")}
	if x := getenv("XDG_CONFIG_HOME"); x != "" {
		dirs = append(dirs, filepath.Join(x, "slipdock"))
	}
	for _, d := range dirs {
		files := []string{filepath.Join(d, "token")}
		more, _ := filepath.Glob(filepath.Join(d, "tokens", "*"))
		for _, f := range append(files, more...) {
			if data, err := os.ReadFile(f); err == nil {
				for _, line := range strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n") {
					secrets = append(secrets, strings.TrimSpace(line))
				}
			}
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, s := range secrets {
		if tokenShape.MatchString(s) && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	// Longest first, so a token that contains another is taken out whole.
	sort.Slice(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}
