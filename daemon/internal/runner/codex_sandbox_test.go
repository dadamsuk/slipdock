package runner

import (
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// A codex job's sandbox and approval flags come from the runner's
// permission mode (#3487).

const codexNetwork = "arg=-c\narg=sandbox_workspace_write.network_access=true\n"

func TestACodexJobsSandboxComesFromItsPermissionMode(t *testing.T) {
	for mode, sandbox := range map[string]string{
		"plan":              "read-only",
		"default":           "workspace-write",
		"acceptEdits":       "workspace-write",
		"bypassPermissions": "danger-full-access",
	} {
		t.Run(mode, func(t *testing.T) {
			r := newRig(t, Config{Agent: "codex", Model: "o4", PermissionMode: mode})
			f := r.runJob(fakeJob{id: 140, kind: "codex", card: 1, prompt: "Do it"})
			if f.exit != 0 {
				t.Fatalf("finish = %+v, want exit 0", f)
			}
			saw := r.agentSaw()
			want := "arg=exec\narg=--sandbox\narg=" + sandbox + "\narg=-c\narg=approval_policy=\"never\"\n"
			if sandbox == "workspace-write" {
				want += codexNetwork
			}
			want += "arg=-m\narg=o4\narg=Do it\n"
			if !strings.Contains(saw, want) {
				t.Fatalf("mode %s: want codex run as\n%s\nit saw:\n%s", mode, want, saw)
			}
			if sandbox != "workspace-write" && strings.Contains(saw, "network_access") {
				t.Fatalf("mode %s: only workspace-write takes a network setting:\n%s", mode, saw)
			}
		})
	}
}

func TestACodexJobWithAModeThatHasNoSandboxIsRefused(t *testing.T) {
	for _, mode := range []string{"", "yolo", "BypassPermissions"} {
		r := newRig(t, Config{Agent: "codex"})
		r.w.Runner.Config.PermissionMode = mode
		f := r.runJob(fakeJob{id: 141, kind: "codex", card: 1, prompt: "Do it"})
		if saw := r.agentSaw(); saw != "" {
			t.Fatalf("mode %q: codex ran:\n%s", mode, saw)
		}
		if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, "no sandbox for permission mode") {
			t.Fatalf("mode %q: finish = %+v; want refused, saying why", mode, f)
		}
	}
}

func TestATiersPermissionModeReachesCodex(t *testing.T) {
	r := newRig(t, Config{Agent: "codex", PermissionMode: "bypassPermissions"})
	r.w.Tiers = map[string]machine.Tier{"owner": {}, "anyone": {MaxPermissionMode: "plan"}}
	r.runJob(fakeJob{id: 142, kind: "codex", card: 1, tier: "anyone", prompt: "Do it"})
	saw := r.agentSaw()
	if !strings.Contains(saw, "arg=--sandbox\narg=read-only\n") || strings.Contains(saw, "danger-full-access") {
		t.Fatalf("an anyone job held to plan runs codex read-only:\n%s", saw)
	}
}

func TestCodexUnderTheConfinedExecutor(t *testing.T) {
	for _, c := range []struct {
		mode, executor, goos string
		sandbox              string // "" for refused
	}{
		// macOS: Codex's sandbox-exec can't run inside confined's.
		{"plan", executor.Confined, "darwin", ""},
		{"default", executor.Confined, "darwin", ""},
		{"acceptEdits", executor.Confined, "darwin", ""},
		{"bypassPermissions", executor.Confined, "darwin", "danger-full-access"},
		// Linux: Landlock under Landlock.
		{"plan", executor.Confined, "linux", "read-only"},
		{"acceptEdits", executor.Confined, "linux", "workspace-write"},
		// Other executors on macOS keep Codex's own sandbox.
		{"plan", executor.Me, "darwin", "read-only"},
		{"acceptEdits", executor.User, "darwin", "workspace-write"},
		{"plan", executor.Container, "darwin", "read-only"},
		// No mode, no sandbox: refused anywhere.
		{"", executor.Me, "linux", ""},
		{"unknown", executor.Confined, "darwin", ""},
	} {
		flags, err := codexSandbox(c.mode, c.executor, c.goos)
		if c.sandbox == "" {
			if err == nil {
				t.Errorf("%s under %s on %s: %v; want refused", c.mode, c.executor, c.goos, flags)
			}
			continue
		}
		if err != nil || len(flags) < 4 || flags[0] != "--sandbox" || flags[1] != c.sandbox ||
			flags[2] != "-c" || flags[3] != `approval_policy="never"` {
			t.Errorf("%s under %s on %s: %v, %v; want --sandbox %s, never asking", c.mode, c.executor, c.goos, flags, err, c.sandbox)
		}
	}
	_, err := codexSandbox("acceptEdits", executor.Confined, "darwin")
	if err == nil || !strings.Contains(err.Error(), "bypassPermissions") {
		t.Fatalf("the refusal says what runs: %v", err)
	}
}

// The worker decides a codex job's sandbox from its own executor and OS:
// on macOS under confined, only bypassPermissions runs, with Codex's
// sandbox off.
func TestACodexJobUnderTheConfinedExecutorOnMacOS(t *testing.T) {
	for _, c := range []struct {
		mode, executor string
		sandbox        string // "" for refused
	}{
		{"acceptEdits", executor.Confined, ""},
		{"plan", executor.Confined, ""},
		{"bypassPermissions", executor.Confined, "danger-full-access"},
		{"acceptEdits", executor.Me, "workspace-write"},
	} {
		t.Run(c.mode+"/"+c.executor, func(t *testing.T) {
			r := newRig(t, Config{Agent: "codex", Model: "o4", PermissionMode: c.mode})
			me, err := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
			if err != nil {
				t.Fatal(err)
			}
			r.w.Executor = named{me, c.executor}
			r.w.GOOS = "darwin"
			f := r.runJob(fakeJob{id: 143, kind: "codex", card: 1, prompt: "Do it"})
			saw := r.agentSaw()
			if c.sandbox == "" {
				if saw != "" {
					t.Fatalf("codex ran:\n%s", saw)
				}
				if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, "can't run inside the confined executor") {
					t.Fatalf("finish = %+v; want refused, saying why", f)
				}
				return
			}
			if f.exit != 0 || !strings.Contains(saw, "arg=exec\narg=--sandbox\narg="+c.sandbox+"\n") {
				t.Fatalf("finish = %+v; want codex run with --sandbox %s, it saw:\n%s", f, c.sandbox, saw)
			}
		})
	}
}
