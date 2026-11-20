package hook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The PreToolUse hook (#3520): a guarded tool waits on the job's mark.

type rig struct {
	srv    *httptest.Server
	asked  atomic.Int32
	answer func(w http.ResponseWriter)
	auth   atomic.Value
}

func newRig(t *testing.T, answer func(w http.ResponseWriter)) *rig {
	r := &rig{answer: answer}
	r.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.asked.Add(1)
		r.auth.Store(req.Header.Get("Authorization") + " " + req.Method + " " + req.URL.Path)
		r.answer(w)
	}))
	t.Cleanup(r.srv.Close)
	return r
}

func (r *rig) run(t *testing.T, stdin string, env map[string]string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	if env == nil {
		env = map[string]string{
			"SLIPDOCK_HOOK_URL": r.srv.URL + "/api/runner/jobs/7/mark",
			"SLIPDOCK_HOOK_KEY": "sdh_k7",
		}
	}
	code := Main([]string{"pretooluse"}, Env{
		Stdin: strings.NewReader(stdin), Stdout: &out, Stderr: &errOut,
		Getenv: func(k string) string { return env[k] },
		HTTP:   r.srv.Client(),
		Sleep:  func(time.Duration) {},
	})
	return code, out.String(), errOut.String()
}

func call(tool string) string {
	return fmt.Sprintf(`{"hook_event_name":"PreToolUse","tool_name":%q,"tool_input":{}}`, tool)
}

// denied is the reason in a deny decision, or "" when out isn't one.
func denied(t *testing.T, out string) string {
	t.Helper()
	if out == "" {
		return ""
	}
	var raw map[string]map[string]string
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		t.Fatalf("not JSON: %q", out)
	}
	o := raw["hookSpecificOutput"]
	if o["hookEventName"] != "PreToolUse" || o["permissionDecision"] != "deny" || o["permissionDecisionReason"] == "" {
		t.Fatalf("not a deny: %q", out)
	}
	return o["permissionDecisionReason"]
}

func TestGuarded(t *testing.T) {
	for tool, want := range map[string]bool{
		"Bash": true, "PowerShell": true, "Monitor": true, "WebFetch": true, "WebSearch": true,
		"mcp__github__push_files": true, "mcp__claude_ai_github__create_branch": true,
		"mcp__claude_ai_Slipdock__get_card": false, "mcp__slipdock__comment": false,
		"Read": false, "Edit": false, "Write": false, "Grep": false, "Glob": false, "TodoWrite": false,
		"bash": false, "": false,
	} {
		if got := Guarded(tool); got != want {
			t.Errorf("Guarded(%q) = %v, want %v", tool, got, want)
		}
	}
}

func TestAnUnguardedToolIsLetThroughUnasked(t *testing.T) {
	r := newRig(t, func(w http.ResponseWriter) { fmt.Fprintln(w, "marked read card #1") })
	code, out, _ := r.run(t, call("Edit"), nil)
	if code != 0 || out != "" || r.asked.Load() != 0 {
		t.Fatalf("exit %d, out %q, asked %d; want 0, nothing, never", code, out, r.asked.Load())
	}
}

func TestAClearJobRunsTheShell(t *testing.T) {
	r := newRig(t, func(w http.ResponseWriter) { fmt.Fprintln(w, "clear") })
	code, out, _ := r.run(t, call("Bash"), nil)
	if code != 0 || out != "" {
		t.Fatalf("exit %d, out %q; want 0 and nothing", code, out)
	}
	if got := r.auth.Load(); got != "Bearer sdh_k7 GET /api/runner/jobs/7/mark" {
		t.Errorf("asked %q", got)
	}
}

func TestAMarkedJobIsRefusedTheShellTheNetworkAndPushing(t *testing.T) {
	r := newRig(t, func(w http.ResponseWriter) { fmt.Fprintln(w, "marked read card #9, with text by anyone") })
	for _, tool := range []string{"Bash", "WebFetch", "WebSearch", "mcp__github__push_files"} {
		code, out, _ := r.run(t, call(tool), nil)
		reason := denied(t, out)
		if code != 0 || !strings.Contains(reason, "read card #9, with text by anyone") {
			t.Errorf("%s: exit %d, reason %q", tool, code, reason)
		}
	}
	// The board's own MCP and the editing tools carry on.
	for _, tool := range []string{"mcp__slipdock__finish_job", "Edit", "Read"} {
		if code, out, _ := r.run(t, call(tool), nil); code != 0 || out != "" {
			t.Errorf("%s: exit %d, out %q; want it let through", tool, code, out)
		}
	}
}

func TestNotFindingOutRefuses(t *testing.T) {
	for name, answer := range map[string]func(http.ResponseWriter){
		"500":     func(w http.ResponseWriter) { w.WriteHeader(500) },
		"401":     func(w http.ResponseWriter) { w.WriteHeader(401); fmt.Fprintln(w, "clear") },
		"unknown": func(w http.ResponseWriter) { fmt.Fprintln(w, "clearly") },
	} {
		r := newRig(t, answer)
		code, out, _ := r.run(t, call("Bash"), nil)
		if reason := denied(t, out); code != 0 || !strings.Contains(reason, "couldn't check") {
			t.Errorf("%s: exit %d, reason %q", name, code, reason)
		}
		if got := r.asked.Load(); got != int32(Tries) {
			t.Errorf("%s: asked %d times, want %d", name, got, Tries)
		}
	}

	r := newRig(t, func(w http.ResponseWriter) { fmt.Fprintln(w, "clear") })
	for _, env := range []map[string]string{
		{},
		{"SLIPDOCK_HOOK_URL": r.srv.URL + "/x"},
		{"SLIPDOCK_HOOK_KEY": "sdh_k"},
		{"SLIPDOCK_HOOK_URL": "file:///etc/passwd", "SLIPDOCK_HOOK_KEY": "sdh_k"},
	} {
		code, out, _ := r.run(t, call("Bash"), env)
		if reason := denied(t, out); code != 0 || !strings.Contains(reason, "couldn't check") {
			t.Errorf("%v: exit %d, reason %q", env, code, reason)
		}
	}
	if r.asked.Load() != 0 {
		t.Error("asked a server it wasn't given")
	}

	code, out, _ := r.run(t, "not json", nil)
	if reason := denied(t, out); code != 0 || !strings.Contains(reason, "couldn't read the tool call") {
		t.Errorf("bad input: exit %d, reason %q", code, reason)
	}
}

func TestATryThatFailsIsTriedAgain(t *testing.T) {
	var n atomic.Int32
	r := newRig(t, func(w http.ResponseWriter) {
		if n.Add(1) == 1 {
			w.WriteHeader(503)
			return
		}
		fmt.Fprintln(w, "clear")
	})
	if code, out, _ := r.run(t, call("Bash"), nil); code != 0 || out != "" {
		t.Fatalf("exit %d, out %q; want the second try's clear", code, out)
	}
}

func TestUsage(t *testing.T) {
	var errOut bytes.Buffer
	for _, args := range [][]string{nil, {"posttooluse"}, {"pretooluse", "x"}} {
		if code := Main(args, Env{Stderr: &errOut}); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
}
