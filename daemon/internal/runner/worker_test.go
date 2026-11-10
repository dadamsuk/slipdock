package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestClaudeJobRunsWithTheRunnersSettings(t *testing.T) {
	r := newRig(t, Config{PermissionMode: "acceptEdits", Model: "sonnet", Instructions: "Be brief."})
	claude := self("agent")
	claude.AllowedTools = []string{"mcp__slipdock", "mcp__other"}
	r.w.Local.Agents["claude"] = claude
	r.w.Local.Models = map[string]string{"schema": "opus"}
	skill := filepath.Join(r.w.Home, ".claude", "skills", "slipdock-loop", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(skill), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skill, []byte("a skill\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	f := r.runJob(fakeJob{id: 101, kind: "claude", card: 42, profile: "feature", prompt: "Build #42"})

	if f.exit != 0 || f.status != "" {
		t.Fatalf("finish = %+v, want exit 0 and no status", f)
	}
	if !strings.Contains(f.body, "hello from the agent") {
		t.Fatalf("the finish carries the log's tail, got %q", f.body)
	}
	saw := r.agentSaw()
	for _, want := range []string{
		"dir=" + realPath(t, r.dir), "pwd-matches=true",
		"arg=-p", `arg=Build #42\n\nBe brief.`,
		"arg=--permission-mode", "arg=acceptEdits",
		"arg=--allowedTools", "arg=mcp__slipdock,mcp__other",
		"arg=--model", "arg=sonnet",
		"env=SLIPDOCK_JOB_ID=101", "env=SLIPDOCK_JOB_KIND=claude", "env=SLIPDOCK_CARD=42",
		"env=SLIPDOCK_CARD_URL=https://slipdock.example.com/boards/3/cards/42",
		"env=SLIPDOCK_PROFILE=feature", "env=SLIPDOCK_MODEL=sonnet",
		"env=CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0",
	} {
		if !strings.Contains(saw, want+"\n") {
			t.Errorf("the agent didn't get %q; it saw:\n%s", want, saw)
		}
	}
	if strings.Contains(saw, "sdm_test_key") {
		t.Fatal("the machine key reached the agent")
	}

	h := r.srv.header(11)
	if got := h.Get("X-Runner-Kinds"); got != "claude,verify,merge,probe" {
		t.Errorf("X-Runner-Kinds = %q", got)
	}
	if got := h.Get("X-Runner-Version"); got != "daemon test" {
		t.Errorf("X-Runner-Version = %q", got)
	}
	sum := sha256.Sum256([]byte("a skill\n"))
	if got := h.Get("X-Runner-Skills"); got != "slipdock-loop="+hex.EncodeToString(sum[:]) {
		t.Errorf("X-Runner-Skills = %q: want the SKILL.md's sha256 without carriage returns", got)
	}
	if got := h.Get("X-Runner-Cli"); got != "none" {
		t.Errorf("X-Runner-CLI = %q", got)
	}
	if got := h.Get("Authorization"); got != "Bearer sdm_test_key" {
		t.Errorf("Authorization = %q", got)
	}
	if !strings.Contains(r.logged.String(), "prompt sha256") {
		t.Errorf("the daemon's log names each job with its prompt's hash:\n%s", r.logged)
	}
}

func TestTheProfilesModelWinsAndVerifyGetsNoInstructions(t *testing.T) {
	r := newRig(t, Config{Model: "sonnet", Instructions: "Be brief."})
	r.w.Local.Models = map[string]string{"schema": "opus"}
	r.runJob(fakeJob{id: 102, kind: "verify", card: 42, profile: "schema", prompt: "Check #42"})
	saw := r.agentSaw()
	if !strings.Contains(saw, "arg=Check #42\n") || strings.Contains(saw, "Be brief.") {
		t.Fatalf("a verify job runs on the server's prompt alone:\n%s", saw)
	}
	if !strings.Contains(saw, "arg=opus\n") || !strings.Contains(saw, "env=SLIPDOCK_MODEL=opus\n") {
		t.Fatalf("the local file's model for the profile wins:\n%s", saw)
	}
}

func TestCodexAndACustomCommand(t *testing.T) {
	r := newRig(t, Config{Agent: "codex", Model: "o4"})
	r.runJob(fakeJob{id: 103, kind: "codex", card: 1, prompt: "Do it"})
	saw := r.agentSaw()
	if !strings.Contains(saw, "arg=exec\narg=-m\narg=o4\narg=Do it\n") {
		t.Fatalf("codex runs as `codex exec -m MODEL PROMPT`:\n%s", saw)
	}
	if strings.Contains(saw, "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS") {
		t.Fatalf("codex gets no Claude settings:\n%s", saw)
	}

	r = newRig(t, Config{Agent: "lint"})
	r.w.Local.Agents["lint"] = self("agent", "--fix")
	r.runJob(fakeJob{id: 104, kind: "lint", card: 1, prompt: "Secret prompt"})
	saw = r.agentSaw()
	if !strings.Contains(saw, "arg=--fix\n") || strings.Contains(saw, "arg=Secret prompt") {
		t.Fatalf("a custom command runs as the local file has it, the prompt never on its command line:\n%s", saw)
	}
	if !strings.Contains(saw, "env=SLIPDOCK_PROMPT=Secret prompt\n") {
		t.Fatalf("the prompt reaches a custom command as $SLIPDOCK_PROMPT:\n%s", saw)
	}
	if got := r.srv.header(11).Get("X-Runner-Kinds"); got != "lint,verify,merge,probe" {
		t.Fatalf("kinds = %q", got)
	}
}

func TestARunnersOwnEnvironmentReachesItsJobsAndHooks(t *testing.T) {
	r := newRig(t, Config{BeforeHook: "setup", AfterHook: "report"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup"), "report": self("hook", "report")}
	r.w.Local.Runners = map[string]machine.RunnerSettings{
		"builder": {Env: map[string]string{"RUNNER_ENV_PROBE": "_build1", "RUNNER_ENV_EMPTY": "",
			"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS": "5"}},
		"verifier": {Env: map[string]string{"RUNNER_ENV_PROBE": "_verify", "RUNNER_ENV_OTHER": "theirs"}},
	}
	// What the daemon itself was started with gives way to the runner's own.
	t.Setenv("RUNNER_ENV_PROBE", "_daemon")
	r.runJob(fakeJob{id: 107, kind: "claude", card: 7, prompt: "x"})
	saw := r.agentSaw()
	for _, want := range []string{"env=RUNNER_ENV_PROBE=_build1", "env=RUNNER_ENV_EMPTY=", "env=SLIPDOCK_JOB_ID=107",
		"env=CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"} {
		if !strings.Contains(saw, want+"\n") {
			t.Errorf("the agent didn't get %q; it saw:\n%s", want, saw)
		}
	}
	for _, not := range []string{"_daemon", "_verify", "RUNNER_ENV_OTHER", "CEILING_MS=5"} {
		if strings.Contains(saw, not) {
			t.Errorf("the agent got %q, which isn't this runner's:\n%s", not, saw)
		}
	}
	if got := r.hooksRan(); got != "setup exit= status= job=107 probe=_build1\nreport exit=0 status=done job=107 probe=_build1\n" {
		t.Fatalf("the hooks get the runner's variables too:\n%s", got)
	}

	// A runner the file doesn't name gets none of them: under me, it keeps
	// what the daemon was started with.
	r = newRig(t, Config{})
	r.w.Local.Runners = map[string]machine.RunnerSettings{"verifier": {Env: map[string]string{"RUNNER_ENV_PROBE": "_verify"}}}
	r.runJob(fakeJob{id: 108, kind: "claude", card: 7, prompt: "x"})
	if saw := r.agentSaw(); !strings.Contains(saw, "env=RUNNER_ENV_PROBE=_daemon\n") || strings.Contains(saw, "_verify") {
		t.Fatalf("a runner with no entry got another's variables:\n%s", saw)
	}
}

func TestAFailedJobAndItsAfterHook(t *testing.T) {
	r := newRig(t, Config{BeforeHook: "setup", AfterHook: "report"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup"), "report": self("hook", "report")}
	t.Setenv("HELPER_EXIT", "3")
	// Whatever started the daemon may have left these set: a job never sees them.
	t.Setenv("SLIPDOCK_EXIT", "99")
	t.Setenv("SLIPDOCK_STATUS", "stale")
	f := r.runJob(fakeJob{id: 105, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 3 || f.status != "" {
		t.Fatalf("finish = %+v, want exit 3", f)
	}
	if got := r.hooksRan(); got != "setup exit= status= job=105\nreport exit=3 status=failed job=105\n" {
		t.Fatalf("hooks ran:\n%s", got)
	}
	if !strings.Contains(f.body, "hook setup ran") || !strings.Contains(f.body, "hook report ran") {
		t.Fatalf("the hooks' output is in the job's log:\n%s", f.body)
	}
}

func TestABeforeHookThatFailsStopsTheJob(t *testing.T) {
	r := newRig(t, Config{BeforeHook: "setup", AfterHook: "report"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup"), "report": self("hook", "report")}
	t.Setenv("HELPER_HOOK_EXIT_setup", "4")
	f := r.runJob(fakeJob{id: 106, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 4 || f.status != "failed" || !strings.Contains(f.body, "the before hook failed (exit 4)") {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatal("the agent ran after its before hook failed")
	}
	if got := r.hooksRan(); !strings.Contains(got, "report exit=4 status=failed") {
		t.Fatalf("the after hook runs whatever happened:\n%s", got)
	}
}

func TestWhatTheLocalFileDoesntDefineFailsBeforeAnythingRuns(t *testing.T) {
	cases := []struct {
		name string
		cfg  Config
		want string
	}{
		{"before hook", Config{BeforeHook: "setup"}, `the before hook "setup" is not defined in this machine's local.json`},
		{"after hook", Config{AfterHook: "report"}, `the after hook "report" is not defined in this machine's local.json`},
		{"custom agent", Config{Agent: "deploy"}, `agent "deploy" is not defined in this machine's local.json`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t, c.cfg)
			r.w.Local.Hooks = map[string]machine.Command{"other": self("hook", "other")}
			kind := c.cfg.Agent
			if kind == "" {
				kind = "claude"
			}
			f := r.runJob(fakeJob{id: 107, kind: kind, card: 7, prompt: "x"})
			if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, c.want) {
				t.Fatalf("finish = %+v, want 127 failed with %q", f, c.want)
			}
			if r.agentSaw() != "" || r.hooksRan() != "" {
				t.Fatal("something ran")
			}
		})
	}

	// A built-in agent that isn't installed fails the same way.
	r := newRig(t, Config{})
	r.w.Local.Agents = nil
	f := r.runJob(fakeJob{id: 108, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 127 || !strings.Contains(f.body, "claude is not on the PATH") {
		t.Fatalf("finish = %+v", f)
	}

	// So does a working directory that isn't there.
	r = newRig(t, Config{})
	if err := os.RemoveAll(r.dir); err != nil {
		t.Fatal(err)
	}
	f = r.runJob(fakeJob{id: 109, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 127 || !strings.Contains(f.body, "is not there") {
		t.Fatalf("finish = %+v", f)
	}
}

func TestAKindTheRunnerDoesntTakeIsRefused(t *testing.T) {
	r := newRig(t, Config{})
	f := r.runJob(fakeJob{id: 110, kind: "deploy", card: 7, prompt: "x"})
	if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, "no such job kind: deploy") {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatal("the agent ran for a kind the runner doesn't take")
	}
	// A kind that isn't a name is dropped before it is compared.
	r = newRig(t, Config{})
	f = r.runJob(fakeJob{id: 111, kind: "claude;rm", card: 7, prompt: "x"})
	if f.exit != 127 || r.agentSaw() != "" {
		t.Fatalf("finish = %+v", f)
	}
}

// ticking says whether the job's child is still writing its tick file.
func ticking(t *testing.T, path string) bool {
	t.Helper()
	before, _ := os.ReadFile(path)
	time.Sleep(300 * time.Millisecond)
	after, _ := os.ReadFile(path)
	return string(before) != string(after)
}

func treeRig(t *testing.T, cfg Config) (*rig, string) {
	r := newRig(t, cfg)
	r.w.Local.Agents["claude"] = self("tree")
	tick := filepath.Join(t.TempDir(), "tick")
	t.Setenv("HELPER_TICK", tick)
	return r, tick
}

func TestTheTimeoutStopsTheJobAndEverythingItStarted(t *testing.T) {
	r, tick := treeRig(t, Config{AfterHook: "report"})
	r.w.Local.Hooks = map[string]machine.Command{"report": self("hook", "report")}
	r.w.Timeout = 1500 * time.Millisecond
	f := r.runJob(fakeJob{id: 120, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 124 || f.status != "timeout" || !strings.Contains(f.body, "slipdock-runner: stopped after") {
		t.Fatalf("finish = %+v", f)
	}
	if !strings.Contains(f.body, "started the tree") {
		t.Fatalf("log: %q", f.body)
	}
	if ticking(t, tick) {
		t.Fatal("the job's child outlived the timeout")
	}
	if got := r.hooksRan(); !strings.Contains(got, "report exit=124 status=timeout") {
		t.Fatalf("hooks: %q", got)
	}
}

// A child that ignores SIGTERM outlives the polite stop: only the forced
// one after the grace ends it. Unix only: on Windows taskkill /F is the
// only stop there is.
func TestAChildThatIgnoresTermIsKilledAfterTheGrace(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no SIGTERM on Windows: taskkill /F forces from the start")
	}
	for _, how := range []string{"timeout", "cancelled"} {
		t.Run(how, func(t *testing.T) {
			r, tick := treeRig(t, Config{})
			r.w.Local.Agents["claude"] = self("stubborn-tree")
			r.w.Grace = 500 * time.Millisecond
			id := int64(124)
			if how == "timeout" {
				r.w.Timeout = 1500 * time.Millisecond
			}
			r.srv.add(fakeJob{runner: 11, id: id, kind: "claude", card: 7, prompt: "x"})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go r.w.Run(ctx)
			waitFor(t, "the child to tick", func() bool { _, err := os.Stat(tick); return err == nil })
			if how == "cancelled" {
				r.srv.mu.Lock()
				r.srv.cancel[id] = true
				r.srv.mu.Unlock()
			}
			waitFor(t, "the finish", func() bool { _, ok := r.srv.finish(id); return ok })
			f, _ := r.srv.finish(id)
			if f.status != how {
				t.Fatalf("finish = %+v, want %s", f, how)
			}
			if ticking(t, tick) {
				t.Fatal("a child that ignores SIGTERM outlived the grace")
			}
		})
	}
}

func TestCancelFromTheBoardStopsTheTree(t *testing.T) {
	r, tick := treeRig(t, Config{})
	r.srv.add(fakeJob{runner: 11, id: 121, kind: "claude", card: 7, prompt: "x"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.w.Run(ctx)
	waitFor(t, "the child to tick", func() bool { _, err := os.Stat(tick); return err == nil })
	waitFor(t, "a heartbeat with the log", func() bool {
		r.srv.mu.Lock()
		defer r.srv.mu.Unlock()
		b := r.srv.beats[121]
		return len(b) > 0 && strings.Contains(b[len(b)-1], "started the tree")
	})
	r.srv.mu.Lock()
	r.srv.cancel[121] = true
	r.srv.mu.Unlock()
	waitFor(t, "the finish", func() bool { _, ok := r.srv.finish(121); return ok })
	f, _ := r.srv.finish(121)
	if f.exit != 130 || f.status != "cancelled" || !strings.Contains(f.body, "cancelled from the board") {
		t.Fatalf("finish = %+v", f)
	}
	if ticking(t, tick) {
		t.Fatal("the job's child outlived the cancel")
	}
}

func TestALostJobIsStoppedAndNotReported(t *testing.T) {
	r, tick := treeRig(t, Config{})
	r.srv.add(fakeJob{runner: 11, id: 122, kind: "claude", card: 7, prompt: "x"})
	r.srv.mu.Lock()
	r.srv.lost[122] = true
	r.srv.mu.Unlock()
	r.run(func() bool { return strings.Contains(r.logged.String(), "no longer this runner's") })
	if _, ok := r.srv.finish(122); ok {
		t.Fatal("a lost job was reported finished: it is another runner's now")
	}
	if ticking(t, tick) {
		t.Fatal("a lost job kept running")
	}
}

func TestTheDaemonStoppingStopsTheJobAndSaysNothing(t *testing.T) {
	r, tick := treeRig(t, Config{})
	r.srv.add(fakeJob{runner: 11, id: 123, kind: "claude", card: 7, prompt: "x"})
	r.run(func() bool { _, err := os.Stat(tick); return err == nil })
	if _, ok := r.srv.finish(123); ok {
		t.Fatal("a job stopped by the daemon stopping was reported: its lease should run out instead")
	}
	if ticking(t, tick) {
		t.Fatal("the job outlived the daemon")
	}
}

func TestTheTranscriptIsSentScrubbedAndCut(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Local.Transcripts = filepath.Join(t.TempDir(), "projects")
	url := "https://slipdock.example.com/boards/3/cards/42"
	long := `{"x":"` + strings.Repeat("a", lineMax+10) + `"}`
	body := `{"text":"` + url + `"}` + "\n" + `{"key":"sdm_test_key here"}` + "\n" + long + "\n" + `{"partial":`
	t.Setenv("HELPER_TRANSCRIPT", filepath.Join(r.w.Local.Transcripts, "proj", "s.jsonl"))
	t.Setenv("HELPER_TRANSCRIPT_BODY", body)
	// Another transcript, for another card, is never sent.
	other := filepath.Join(r.w.Local.Transcripts, "proj", "other.jsonl")
	if err := os.MkdirAll(filepath.Dir(other), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte(`{"text":"cards/99"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	r.runJob(fakeJob{id: 130, kind: "claude", card: 42, prompt: "x"})
	got := r.srv.transcript[130]
	if len(got) != 3 {
		t.Fatalf("sent %d lines, want the 3 whole ones: %q", len(got), got)
	}
	if got[1] != `{"key":"[redacted] here"}` {
		t.Errorf("line 2 = %q: the machine key is taken out", got[1])
	}
	if !strings.HasPrefix(got[2], `{"type":"slipdock_cut","bytes":`) {
		t.Errorf("line 3 = %.80q: a line over the limit is replaced", got[2])
	}
}

func TestATranscriptTheServerCapsStopsBeingSent(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.txCap = 1
	r.w.Local.Transcripts = filepath.Join(t.TempDir(), "projects")
	t.Setenv("HELPER_TRANSCRIPT", filepath.Join(r.w.Local.Transcripts, "s.jsonl"))
	t.Setenv("HELPER_TRANSCRIPT_BODY", `{"u":"https://slipdock.example.com/boards/3/cards/42"}`+"\n{}\n{}\n")
	f := r.runJob(fakeJob{id: 131, kind: "claude", card: 42, prompt: "x"})
	if n := len(r.srv.transcript[131]); n != 3 {
		// The first send carries all three; the cap stops any more.
		t.Fatalf("sent %d lines", n)
	}
	if !strings.Contains(f.body, "the server's log for this job is full") {
		t.Fatalf("log: %q", f.body)
	}
}

func TestMachineSecretsIncludeTheCLIsTokens(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".config", "slipdock", "tokens")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".config", "slipdock", "token"), []byte("sdk_cli_token_1\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "board"), []byte("sdk_board_token_2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := machineSecrets("sdm_machine_key", home, func(k string) string {
		return map[string]string{"SLIPDOCK_TOKEN": "sdk_env_token_3", "XDG_CONFIG_HOME": ""}[k]
	}, executor.LocalFiles)
	for _, want := range []string{"sdm_machine_key", "sdk_cli_token_1", "sdk_board_token_2", "sdk_env_token_3"} {
		found := false
		for _, s := range got {
			found = found || s == want
		}
		if !found {
			t.Errorf("%s missing from %q", want, got)
		}
	}
	out := scrub([]byte("a sdk_env_token_3 b sdm_machine_key"), got)
	if string(out) != "a [redacted] b [redacted]" {
		t.Fatalf("scrub = %q", out)
	}
}

func TestAWorktreePerJob(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	r := newRig(t, Config{Worktree: "on"})
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.com"}, args...)...)
		cmd.Dir = r.dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q")
	git("commit", "-q", "--allow-empty", "-m", "start")

	out, err := exec.Command("git", "-C", r.dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		t.Fatal(err)
	}
	top := filepath.Clean(strings.TrimSpace(string(out)))
	f := r.runJob(fakeJob{id: 140, kind: "claude", card: 55, prompt: "x"})
	lane := filepath.Join(top+"-lanes", "card-55")
	saw := r.agentSaw()
	if !strings.Contains(saw, "env=SLIPDOCK_WORKTREE="+lane+"\n") {
		t.Fatalf("the job runs in its card's worktree (%s):\n%s", lane, saw)
	}
	if !strings.Contains(f.body, "worktree "+lane+" on branch card-55") || !strings.Contains(f.body, "removed") {
		t.Fatalf("log: %s", f.body)
	}
	if _, err := os.Stat(lane); !os.IsNotExist(err) {
		t.Fatal("a clean worktree is removed after the job")
	}

	// With auto, only when another runner shares the directory.
	r.w.Runner.Config.Worktree = "auto"
	r.w.SharedDir = false
	f = r.runJob(fakeJob{id: 141, kind: "claude", card: 56, prompt: "x"})
	if strings.Contains(f.body, "worktree") {
		t.Fatalf("auto with the directory to itself: no worktree; log: %s", f.body)
	}
	r.w.SharedDir = true
	f = r.runJob(fakeJob{id: 142, kind: "claude", card: 57, prompt: "x"})
	if !strings.Contains(f.body, "on branch card-57") {
		t.Fatalf("auto in a shared directory: a worktree; log: %s", f.body)
	}

	// A path that is there but isn't a worktree: the job isn't run.
	bad := filepath.Join(top+"-lanes", "card-58")
	if err := os.MkdirAll(bad, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(r.out, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	f = r.runJob(fakeJob{id: 143, kind: "claude", card: 58, prompt: "x"})
	if f.exit != 1 || f.status != "failed" || r.agentSaw() != "" {
		t.Fatalf("finish = %+v", f)
	}
}

func TestClaimsBackOffAndHonourRetryAfter(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Client.Server = "http://127.0.0.1:1" // nothing answers
	var slept []time.Duration
	r.w.Sleep = func(ctx context.Context, d time.Duration) error {
		slept = append(slept, d)
		if len(slept) >= 4 {
			return context.Canceled
		}
		return nil
	}
	if err := r.w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(slept) != 4 || slept[0] != time.Second || slept[1] != 2*time.Second || slept[3] != 8*time.Second {
		t.Fatalf("waits = %v, want doubling from a second", slept)
	}
}

func TestATranscriptFromBeforeTheJobIsNeverSent(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Local.Transcripts = filepath.Join(t.TempDir(), "projects")
	url := "https://slipdock.example.com/boards/3/cards/42"
	// An earlier job's transcript for the same card, written before this
	// one started.
	old := filepath.Join(r.w.Local.Transcripts, "proj", "a-old.jsonl") // listed first
	if err := os.MkdirAll(filepath.Dir(old), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(old, []byte(`{"old":"`+url+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	then := time.Now().Add(-time.Hour)
	if err := os.Chtimes(old, then, then); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HELPER_TRANSCRIPT", filepath.Join(r.w.Local.Transcripts, "proj", "new.jsonl"))
	t.Setenv("HELPER_TRANSCRIPT_BODY", `{"new":"`+url+`"}`+"\n")
	r.runJob(fakeJob{id: 132, kind: "claude", card: 42, prompt: "x"})
	got := r.srv.transcript[132]
	if len(got) != 1 || !strings.Contains(got[0], `"new"`) {
		t.Fatalf("sent %q: want only this job's transcript", got)
	}
}

// Each job is written to its runner's job.json as it starts and when it
// ends, for slipdock-runner status (#2652).
func TestAJobIsRecordedForStatus(t *testing.T) {
	r := newRig(t, Config{})
	r.runJob(fakeJob{id: 110, kind: "claude", card: 42, prompt: "x"})
	j, err := daemonstate.LoadJob(r.w.JobsDir, r.w.Runner.ID)
	if err != nil || j == nil {
		t.Fatalf("job.json: %v %v", j, err)
	}
	if j.ID != 110 || j.CardID != 42 || j.Kind != "claude" || j.Started.IsZero() || j.Finished == nil || j.Status != "succeeded" {
		t.Fatalf("job.json = %+v", j)
	}

	t.Setenv("HELPER_EXIT", "3")
	r.runJob(fakeJob{id: 111, kind: "claude", card: 43, prompt: "x"})
	if j, _ := daemonstate.LoadJob(r.w.JobsDir, r.w.Runner.ID); j.ID != 111 || j.CardID != 43 || j.Status != "failed" {
		t.Fatalf("job.json after a failed job = %+v", j)
	}
}

// A job the worker lets go without reporting it finished (the daemon
// stopping while it ran) is recorded as stopped, and a job that is
// running shows no end.
func TestAJobCutShortIsRecordedAsStopped(t *testing.T) {
	r := newRig(t, Config{})
	r.w.defaults()
	r.w.held = &daemonstate.Job{ID: 120, CardID: 9, Kind: "claude", Started: time.Now()}
	r.w.recordJob()
	if j, _ := daemonstate.LoadJob(r.w.JobsDir, r.w.Runner.ID); j == nil || j.Finished != nil {
		t.Fatalf("a running job's job.json = %+v", j)
	}
	r.w.letGo()
	j, _ := daemonstate.LoadJob(r.w.JobsDir, r.w.Runner.ID)
	if j == nil || j.ID != 120 || j.Finished == nil || j.Status != "stopped" || r.w.held != nil {
		t.Fatalf("job.json = %+v, held %v", j, r.w.held)
	}
}

func TestEndedAs(t *testing.T) {
	for _, tc := range []struct {
		rc     int
		status string
		want   string
	}{{0, "", "succeeded"}, {3, "", "failed"}, {0, "cancelled", "cancelled"}, {1, "timeout", "timeout"}} {
		if got := endedAs(tc.rc, tc.status); got != tc.want {
			t.Errorf("endedAs(%d, %q) = %q, want %q", tc.rc, tc.status, got, tc.want)
		}
	}
}

// A runner's line keeps its level: the marker goes before the runner's name.
func TestSayKeepsTheLevelMarker(t *testing.T) {
	var got []string
	w := &Worker{Runner: Runner{ID: 4, Name: "builder"}, Logf: func(f string, a ...any) { got = append(got, fmt.Sprintf(f, a...)) }}
	w.say("warn: could not reach the queue (%s)", "down")
	w.say("taking jobs")
	w.say("error: job #%d: can't open it", 9)
	w.say("debug: a detail")
	want := []string{"warn: runner builder (#4): could not reach the queue (down)", "runner builder (#4): taking jobs",
		"error: runner builder (#4): job #9: can't open it", "debug: runner builder (#4): a detail"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}
