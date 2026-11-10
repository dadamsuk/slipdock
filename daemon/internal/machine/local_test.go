package machine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadLocalMissingIsEmpty(t *testing.T) {
	l, err := LoadLocal(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if c, ok := l.Agent("claude"); !ok || c.Path != "claude" {
		t.Fatalf("claude with no file = %+v %v: want it found on the PATH", c, ok)
	}
	if c, ok := l.Agent("codex"); !ok || c.Path != "codex" {
		t.Fatalf("codex with no file = %+v %v", c, ok)
	}
	if _, ok := l.Agent("deploy"); ok {
		t.Fatal("a custom agent the file doesn't define was found")
	}
	if _, ok := l.Hook("setup"); ok {
		t.Fatal("a hook the file doesn't define was found")
	}
}

func TestLoadLocalReadsAgentsAndHooks(t *testing.T) {
	d := t.TempDir()
	body := `{"agents":{"claude":{"path":"/opt/claude","allowed_tools":["mcp__slipdock"]},"lint":{"path":"/usr/bin/make","args":["lint"]}},
	"hooks":{"setup":{"path":"/usr/local/bin/setup.sh"}},"models":{"schema":"opus"},"no_merge":true,"no_skills_update":true,"no_cli_update":true,"cli_checksum_only":true}`
	if err := os.WriteFile(filepath.Join(d, LocalFile), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := LoadLocal(d)
	if err != nil {
		t.Fatal(err)
	}
	if c, _ := l.Agent("claude"); c.Path != "/opt/claude" || c.AllowedTools[0] != "mcp__slipdock" {
		t.Fatalf("claude = %+v: the file's entry wins over the PATH", c)
	}
	if c, ok := l.Agent("lint"); !ok || c.Args[0] != "lint" {
		t.Fatalf("lint = %+v %v", c, ok)
	}
	if c, ok := l.Hook("setup"); !ok || c.Path != "/usr/local/bin/setup.sh" {
		t.Fatalf("setup = %+v %v", c, ok)
	}
	if l.Models["schema"] != "opus" || !l.NoMerge || !l.NoSkillsUpdate || !l.NoCLIUpdate || !l.CLIChecksumOnly {
		t.Fatalf("%+v", l)
	}
}

func TestLoadLocalRefusesWhatItDoesntKnow(t *testing.T) {
	for name, body := range map[string]string{
		"unknown field":   `{"agents":{},"command":"rm -rf /"}`,
		"empty path":      `{"hooks":{"setup":{"path":" "}}}`,
		"bad name":        `{"agents":{"Bad Name":{"path":"/bin/x"}}}`,
		"not JSON":        `{`,
		"unknown in hook": `{"hooks":{"setup":{"path":"/x","shell":"sh"}}}`,
	} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, LocalFile), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadLocal(d); err == nil || !strings.Contains(err.Error(), LocalFile) {
			t.Errorf("%s: err = %v, want one naming %s", name, err, LocalFile)
		}
	}
}

func TestTheLocalFileNamesTheAccountAndWhatConfinedMayWrite(t *testing.T) {
	d := t.TempDir()
	abs := t.TempDir()
	l := Local{User: &Account{Name: "slipdock", Home: abs}, ConfinedWritable: []string{filepath.Join(abs, ".claude")}}
	if err := SaveLocal(d, l); err != nil {
		t.Fatal(err)
	}
	got, err := LoadLocal(d)
	if err != nil || got.User == nil || *got.User != *l.User || len(got.ConfinedWritable) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	for _, bad := range []Local{
		{User: &Account{Name: "", Home: "/srv/x"}},
		{User: &Account{Name: "x", Home: "home/x"}},
		{ConfinedWritable: []string{"relative"}},
	} {
		if err := SaveLocal(d, bad); err == nil {
			t.Errorf("saved %+v", bad)
		}
	}
}

func TestTheLocalFileSaysHowContainersRun(t *testing.T) {
	d := t.TempDir()
	abs := t.TempDir()
	l := Local{Container: &ContainerSettings{Runtime: "podman", Pull: "missing",
		Login: []string{filepath.Join(abs, ".claude", ".credentials.json")}, Env: []string{"CLAUDE_CODE_OAUTH_TOKEN"}}}
	if err := SaveLocal(d, l); err != nil {
		t.Fatal(err)
	}
	got, err := LoadLocal(d)
	if err != nil || got.Container == nil || got.Container.Runtime != "podman" || got.Container.Pull != "missing" ||
		len(got.Container.Login) != 1 || got.Container.Env[0] != "CLAUDE_CODE_OAUTH_TOKEN" {
		t.Fatalf("%+v %v", got.Container, err)
	}
	for _, c := range []struct {
		bad  ContainerSettings
		want string
	}{
		{ContainerSettings{Pull: "sometimes"}, "container.pull"},
		{ContainerSettings{Login: []string{".claude"}}, "container.login"},
		{ContainerSettings{Env: []string{"SLIPDOCK_TOKEN"}}, "never pass"},
		{ContainerSettings{Env: []string{"HOME"}}, "container's own"},
		{ContainerSettings{Runtime: " docker"}, "container.runtime"},
	} {
		bad := c.bad
		if err := SaveLocal(d, Local{Container: &bad}); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("saved %+v: %v", c.bad, err)
		}
	}
}

// log_level sets the daemon's log level (#2652): one of four, or unset.
func TestTheLocalFileSetsTheLogLevel(t *testing.T) {
	d := t.TempDir()
	for _, level := range []string{"debug", "info", "warn", "error"} {
		os.WriteFile(filepath.Join(d, LocalFile), []byte(`{"log_level":"`+level+`"}`), 0o644)
		if l, err := LoadLocal(d); err != nil || l.LogLevel != level {
			t.Fatalf("%s: %+v %v", level, l, err)
		}
	}
	os.WriteFile(filepath.Join(d, LocalFile), []byte(`{"log_level":"loud"}`), 0o644)
	if _, err := LoadLocal(d); err == nil || !strings.Contains(err.Error(), `log_level: "loud" is not one of debug, info, warn, error`) {
		t.Fatalf("a level that isn't one: %v", err)
	}
}

func TestTheLocalFileSetsARunnersEnvironment(t *testing.T) {
	d := t.TempDir()
	body := `{"runners":{"build 1":{"env":{"MIX_TEST_PARTITION":"_build1","A_FLAG":""}},"verify":{"env":{"MIX_TEST_PARTITION":"_verify"}},"bare":{}}}`
	if err := os.WriteFile(filepath.Join(d, LocalFile), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := LoadLocal(d)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.RunnerEnv("build 1"), " "); got != "A_FLAG= MIX_TEST_PARTITION=_build1" {
		t.Errorf("build 1's = %q: want its own, in the names' order", got)
	}
	if got := strings.Join(l.RunnerEnv("verify"), " "); got != "MIX_TEST_PARTITION=_verify" {
		t.Errorf("verify's = %q", got)
	}
	for _, name := range []string{"bare", "nobody", "Verify", ""} {
		if got := l.RunnerEnv(name); len(got) != 0 {
			t.Errorf("%q gets %q: want nothing", name, got)
		}
	}
	if got := (Local{}).RunnerEnv("verify"); len(got) != 0 {
		t.Errorf("with no file, verify gets %q", got)
	}
	// It survives a save, as init's rewrite of the file does.
	if err := SaveLocal(d, l); err != nil {
		t.Fatal(err)
	}
	if again, err := LoadLocal(d); err != nil || again.Runners["verify"].Env["MIX_TEST_PARTITION"] != "_verify" {
		t.Fatalf("after a save: %+v %v", again, err)
	}
}

func TestTheLocalFileRefusesARunnersVariableItCantSet(t *testing.T) {
	for body, want := range map[string]string{
		`{"runners":{"b":{"env":{"SLIPDOCK_JOB_ID":"1"}}}}`: "runners.b.env: SLIPDOCK_JOB_ID: the SLIPDOCK_* variables are the daemon's to set",
		`{"runners":{"b":{"env":{"slipdock_token":"x"}}}}`:  "the daemon's to set",
		`{"runners":{"b":{"env":{"PATH":"/tmp"}}}}`:         "runners.b.env: PATH is the executor's own",
		`{"runners":{"b":{"env":{"home":"/tmp"}}}}`:         "home is the executor's own",
		`{"runners":{"b":{"env":{"A=B":"x"}}}}`:             `runners.b.env: "A=B" is not a variable's name`,
		`{"runners":{"b":{"env":{"":"x"}}}}`:                "is not a variable's name",
		`{"runners":{"b":{"env":{"OK":"a\u0000b"}}}}`:       "runners.b.env: OK has a NUL in its value",
		`{"runners":{" ":{"env":{"OK":"x"}}}}`:              "runners: a runner's name is empty",
		`{"runners":{"b":{"env":{"OK":1}}}}`:                "cannot unmarshal",
		`{"runners":{"b":{"environment":{"OK":"x"}}}}`:      "unknown field",
		`{"runners":{"b":{"env":{"OK":"x","1BAD":"y"}}}}`:   `"1BAD" is not a variable's name`,
	} {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, LocalFile), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadLocal(d); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: err = %v, want %q", body, err, want)
		}
	}
}
