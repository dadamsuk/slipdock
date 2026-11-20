package runner

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// The read-mark hook a Claude Code job gets (#3520).

func TestTheHookKeyIsReadFromTheClaim(t *testing.T) {
	for header, want := range map[string]string{
		"sdh_abc-DEF_123":                "sdh_abc-DEF_123",
		"":                               "",
		"sdh_":                           "",
		"abc":                            "",
		"sdr_abc":                        "",
		"sdh_a b":                        "",
		"sdh_a;rm -rf":                   "",
		"sdh_" + strings.Repeat("a", 65): "",
	} {
		h := http.Header{}
		h.Set("X-Job-Id", "5")
		if header != "" {
			h.Set("X-Job-Hook-Key", header)
		}
		job, err := parseJob(h, nil)
		if err != nil || job.HookKey != want {
			t.Errorf("X-Job-Hook-Key %q: key %q, err %v; want %q", header, job.HookKey, err, want)
		}
	}
}

func TestAClaudeJobGetsTheHookAndWhatItAsksWith(t *testing.T) {
	r := newRig(t, Config{PermissionMode: "bypassPermissions"})
	r.w.Launcher = "/opt/slipdock it's/slipdock-runner"
	f := r.runJob(fakeJob{id: 130, kind: "claude", card: 7, hookKey: "sdh_key130", prompt: "x"})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	saw := r.agentSaw()
	for _, want := range []string{
		"env=SLIPDOCK_HOOK_KEY=sdh_key130",
		"env=SLIPDOCK_HOOK_URL=" + r.w.Client.Server + "/api/runner/jobs/130/mark",
		"arg=--settings",
	} {
		if !strings.Contains(saw, want+"\n") {
			t.Errorf("the agent didn't get %q; it saw:\n%s", want, saw)
		}
	}
	settings := argAfter(saw, "--settings")
	var got struct {
		Hooks map[string][]struct {
			Matcher string `json:"matcher"`
			Hooks   []struct {
				Type, Command string
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(settings), &got); err != nil {
		t.Fatalf("--settings %q: %v", settings, err)
	}
	pre := got.Hooks["PreToolUse"]
	if len(pre) != 1 || len(pre[0].Hooks) != 1 {
		t.Fatalf("PreToolUse = %+v", pre)
	}
	if pre[0].Matcher != hookMatcher || !strings.Contains(pre[0].Matcher, "Bash") || !strings.Contains(pre[0].Matcher, "WebFetch") {
		t.Errorf("matcher = %q", pre[0].Matcher)
	}
	if h := pre[0].Hooks[0]; h.Type != "command" || h.Command != `'/opt/slipdock it'\''s/slipdock-runner' hook pretooluse` {
		t.Errorf("hook = %+v; want the daemon's own binary, quoted", h)
	}
	if strings.Contains(settings, "sdh_key130") {
		t.Error("the key is in the command line; it belongs in the environment")
	}
}

func TestNoHookWithoutAKeyOrForAnotherAgent(t *testing.T) {
	r := newRig(t, Config{})
	r.runJob(fakeJob{id: 131, kind: "claude", card: 7, prompt: "x"})
	if saw := r.agentSaw(); strings.Contains(saw, "--settings") || strings.Contains(saw, "SLIPDOCK_HOOK_") {
		t.Fatalf("a job with no hook key got the hook:\n%s", saw)
	}

	r = newRig(t, Config{Agent: "codex"})
	r.runJob(fakeJob{id: 132, kind: "codex", card: 7, hookKey: "sdh_k", prompt: "x"})
	if saw := r.agentSaw(); strings.Contains(saw, "--settings") || strings.Contains(saw, "SLIPDOCK_HOOK_") {
		t.Fatalf("codex got Claude Code's hook:\n%s", saw)
	}
}

func TestTheHookIsOnlyWhereTheDaemonsBinaryRuns(t *testing.T) {
	job := &Job{ID: 1, HookKey: "sdh_k"}
	w := &Worker{Runner: Runner{Config: Config{Agent: "claude"}}, Launcher: "/bin/slipdock-runner",
		Client: &Client{Server: "https://slipdock.example.com/"}}
	if !w.hooked(job) || w.hookSettings(job) == "" {
		t.Fatal("a local job has no hook")
	}
	if got := w.markURL(job); got != "https://slipdock.example.com/api/runner/jobs/1/mark" {
		t.Errorf("markURL = %q", got)
	}
	w.Launcher = ""
	if w.hooked(job) {
		t.Error("hooked with no binary to run")
	}
	w.Launcher = "/bin/slipdock-runner"
	ex, err := executor.New(executor.Container, executor.Settings{GOOS: "linux", Image: "img", Images: []string{"img"}})
	if err != nil {
		t.Fatal(err)
	}
	w.Executor = ex
	if w.hooked(job) || w.hookSettings(job) != "" {
		t.Error("a container job got a hook its image can't run")
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote(`C:\Program Files\slipdock-runner.exe`, "windows"); got != `"C:\Program Files\slipdock-runner.exe"` {
		t.Errorf("windows: %s", got)
	}
	if got := shellQuote("/a b/c", "linux"); got != "'/a b/c'" {
		t.Errorf("linux: %s", got)
	}
}

// argAfter is the arg the fake agent saw after flag.
func argAfter(saw, flag string) string {
	lines := strings.Split(saw, "\n")
	for i, l := range lines {
		if l == "arg="+flag && i+1 < len(lines) {
			return strings.TrimPrefix(lines[i+1], "arg=")
		}
	}
	return ""
}
