package runner

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// claudeConfig is what of ~/.claude a later session loads: a confined job
// may write none of it (#3485).
var claudeConfig = []string{"settings.json", "settings.local.json", "hooks/h.sh", "skills/s/SKILL.md", "plugins/p",
	"commands/c.md", "agents/a.md", "output-styles/o.md", "CLAUDE.md", "shell-snapshots/s.sh", "session-env/s/e",
	"sessions/1.json", "ide/1.lock", "state/s.json", "statsig/s", "backups/b"}

// covers is whether writing path is granted by one of writable.
func covers(writable []string, path string) bool {
	for _, w := range writable {
		if path == w || strings.HasPrefix(path, w+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func TestAConfinedClaudeJobWritesOnlyItsSessionState(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Runner.Config.Executor = executor.Confined
	claude := filepath.Join(r.w.Home, ".claude")
	w := r.w.settingsFor(executor.Confined).Writable
	if slices.Contains(w, claude) {
		t.Fatalf("the whole of ~/.claude is writable: %v", w)
	}
	for _, want := range []string{"projects", "todos", "tasks", "file-history", "debug", ".credentials.json", "history.jsonl"} {
		if !slices.Contains(w, filepath.Join(claude, want)) {
			t.Errorf("%s isn't writable: %v", want, w)
		}
	}
	for _, c := range claudeConfig {
		if covers(w, filepath.Join(claude, filepath.FromSlash(c))) {
			t.Errorf("%s is writable: %v", c, w)
		}
	}

	// The daemon makes the state directories, which the job can't, and the
	// macOS profile grants them alone.
	r.w.makeClaudeState()
	for _, d := range claudeStateDirs {
		fi, err := os.Stat(filepath.Join(claude, d))
		// Windows keeps no Unix mode: only that it was made.
		if err != nil || !fi.IsDir() || runtime.GOOS != "windows" && fi.Mode().Perm() != 0o700 {
			t.Fatalf("%s wasn't made, owner-only: %v %v", d, fi, err)
		}
	}
	profile := executor.SandboxProfile(w, nil, nil)
	// The profile quotes a path as SBPL does (a Windows path's backslashes
	// doubled), so the paths are looked for quoted the same way.
	subpath := func(p string) string { return `(subpath "` + strings.ReplaceAll(p, `\`, `\\`) + `")` }
	if strings.Contains(profile, subpath(claude)) || !strings.Contains(profile, subpath(filepath.Join(claude, "projects"))) {
		t.Fatalf("the macOS profile:\n%s", profile)
	}

	// The command line this machine confines it with (Landlock's --write
	// rules, or the profile) grants the state there is and none of the
	// config.
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		return
	}
	s := r.w.settingsFor(executor.Confined)
	s.GOOS, s.Launcher = runtime.GOOS, os.Args[0]
	ex, err := executor.New(executor.Confined, s)
	if err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err != nil {
		t.Logf("no sandbox here: %v", err)
		return
	}
	cmd, err := ex.Command(executor.Proc{Dir: r.dir}, "/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	real, _ := filepath.EvalSymlinks(claude)
	var granted []string
	for i, a := range cmd.Args {
		switch {
		case a == "--write" && i+1 < len(cmd.Args):
			granted = append(granted, cmd.Args[i+1])
		case strings.HasPrefix(a, "(version 1)"):
			// Only the write grants: the profile's read rules name
			// subpaths too.
			_, block, _ := strings.Cut(a, "(allow file-write*\n")
			block, _, _ = strings.Cut(block, `(literal "/dev/null")`)
			for _, line := range strings.Split(block, "\n") {
				if p, ok := strings.CutPrefix(strings.TrimSpace(line), `(subpath "`); ok {
					granted = append(granted, strings.TrimSuffix(p, `")`))
				}
			}
		}
	}
	if !slices.Contains(granted, filepath.Join(real, "projects")) || slices.Contains(granted, real) {
		t.Fatalf("granted %v", granted)
	}
	if slices.Contains(granted, filepath.Join(real, "history.jsonl")) {
		t.Fatalf("a state file that isn't there is granted: %v", granted)
	}
	for _, c := range claudeConfig {
		if covers(granted, filepath.Join(real, filepath.FromSlash(c))) {
			t.Errorf("%s is granted: %v", c, granted)
		}
	}
}

func TestClaudesStateFollowsItsConfigDirectory(t *testing.T) {
	r := newRig(t, Config{})
	dir := filepath.Join(t.TempDir(), "claude-config")
	r.w.Getenv = func(k string) string {
		if k == "CLAUDE_CONFIG_DIR" {
			return dir
		}
		return ""
	}
	w := r.w.settingsFor(executor.Confined).Writable
	if !slices.Contains(w, filepath.Join(dir, "projects")) || covers(w, filepath.Join(r.w.Home, ".claude", "projects")) {
		t.Fatalf("writable: %v", w)
	}
}

func TestARelativeConfigDirectoryIsNotClaudes(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Getenv = func(k string) string {
		if k == "CLAUDE_CONFIG_DIR" {
			return filepath.Join("relative", "claude")
		}
		return ""
	}
	w := r.w.settingsFor(executor.Confined).Writable
	if !slices.Contains(w, filepath.Join(r.w.Home, ".claude", "projects")) || covers(w, filepath.Join("relative", "claude", "projects")) {
		t.Fatalf("a relative CLAUDE_CONFIG_DIR is ~/.claude's: %v", w)
	}
}

func TestNoHomeMeansNoneOfClaudesState(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Home = ""
	r.w.Getenv = func(string) string { return "" }
	if w := r.w.settingsFor(executor.Confined).Writable; len(w) != 0 {
		t.Fatalf("with no home: %v", w)
	}
	cwd := t.TempDir()
	t.Chdir(cwd)
	r.w.makeClaudeState()
	if _, err := os.Stat(filepath.Join(cwd, ".claude")); err == nil {
		t.Fatal("with no home, the daemon made a relative .claude")
	}
}

func TestAnotherAgentsStateIsNotMade(t *testing.T) {
	r := newRig(t, Config{Agent: "codex"})
	r.w.makeClaudeState()
	if _, err := os.Stat(filepath.Join(r.w.Home, ".claude")); err == nil {
		t.Fatal("the daemon made Claude's state for a codex runner")
	}
}

func TestConfinedWritableOverridesClaudesSessionState(t *testing.T) {
	r := newRig(t, Config{})
	own := filepath.Join(t.TempDir(), "mine")
	r.w.Local.ConfinedWritable = []string{own}
	if w := r.w.settingsFor(executor.Confined).Writable; !slices.Equal(w, []string{own}) {
		t.Fatalf("the local file's confined_writable: %v", w)
	}
	r.w.makeClaudeState()
	if _, err := os.Stat(filepath.Join(r.w.Home, ".claude")); err == nil {
		t.Fatal("the daemon made Claude's state though the local file names what is writable")
	}

	// Another agent gets none of Claude's.
	r = newRig(t, Config{Agent: "codex"})
	if w := r.w.settingsFor(executor.Confined).Writable; len(w) != 0 {
		t.Fatalf("codex: %v", w)
	}
}

func TestAConfinedClaudeJobCantWriteItsConfig(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	probe, _ := executor.New(executor.Confined, executor.Settings{GOOS: runtime.GOOS, Launcher: os.Args[0]})
	if err := probe.Ready(); err != nil {
		if os.Getenv("SLIPDOCK_EXECUTOR_TESTS") == "1" {
			t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but %v", err)
		}
		t.Skip(err)
	}
	r := newRig(t, Config{})
	r.w.Runner.Config.Executor = executor.Confined
	// The daemon's own directory, which a confined job can't read, beside
	// the home as on a machine, not holding it as the rig's would.
	r.w.MachineDir = filepath.Join(filepath.Dir(r.w.JobsDir), "machine")
	claude := filepath.Join(r.w.Home, ".claude")
	mcp := filepath.Join(r.w.Home, ".claude.json")
	settings, skill := filepath.Join(claude, "settings.json"), filepath.Join(claude, "skills", "s", "SKILL.md")
	for path, body := range map[string]string{settings: "{}", skill: "a skill", filepath.Join(claude, "CLAUDE.md"): "notes",
		mcp: `{"mcpServers":{}}`} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var writes []string
	for _, c := range claudeConfig {
		writes = append(writes, filepath.Join(claude, filepath.FromSlash(c)))
	}
	writes = append(writes, filepath.Join(claude, "skills", "x"))
	transcript, todo := filepath.Join(claude, "projects", "p", "s.jsonl"), filepath.Join(claude, "todos", "t.json")
	writes = append(writes, transcript, todo)
	t.Setenv("HELPER_WRITES", strings.Join(writes, string(filepath.ListSeparator)))
	t.Setenv("HELPER_READS", strings.Join([]string{settings, skill, mcp}, string(filepath.ListSeparator)))

	// What it saw goes in its own directory: it can't write the rig's.
	r.out = filepath.Join(r.dir, "agent.out")
	t.Setenv("HELPER_OUT", r.out)

	f := r.runJob(fakeJob{id: 305, kind: "claude", card: 7, prompt: "x"})
	saw := r.agentSaw()
	if f.exit != 0 || saw == "" {
		t.Fatalf("finish %+v; the agent saw:\n%s", f, saw)
	}
	for _, path := range writes[:len(writes)-2] {
		if !strings.Contains(saw, "refused="+path+"\n") {
			t.Errorf("a confined claude job wrote %s:\n%s", path, saw)
		}
	}
	for _, path := range []string{transcript, todo} {
		if !strings.Contains(saw, "wrote="+path+"\n") {
			t.Errorf("a confined claude job couldn't write its state %s:\n%s", path, saw)
		}
	}
	// Its skills and MCP config are where they were, and it reads them.
	for _, path := range []string{settings, skill, mcp} {
		if !strings.Contains(saw, "read="+path+"\n") {
			t.Errorf("a confined claude job couldn't read %s:\n%s", path, saw)
		}
	}
	if data, _ := os.ReadFile(settings); string(data) != "{}" {
		t.Fatalf("settings.json changed: %q", data)
	}
	if data, _ := os.ReadFile(skill); string(data) != "a skill" {
		t.Fatalf("the skill changed: %q", data)
	}
}
