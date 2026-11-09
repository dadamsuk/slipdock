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
	"hooks":{"setup":{"path":"/usr/local/bin/setup.sh"}},"models":{"schema":"opus"},"no_merge":true}`
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
	if l.Models["schema"] != "opus" || !l.NoMerge {
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
