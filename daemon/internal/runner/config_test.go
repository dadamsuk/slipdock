package runner

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestTheExecutorMustBeOfferedAndRunnable(t *testing.T) {
	root := filepath.Join(t.TempDir(), "src")
	runner := func(ex string) Runner {
		return Runner{ID: 1, BoardID: 3, Config: Config{Agent: "claude", Directory: filepath.Join(root, "repo"),
			PermissionMode: "default", TimeoutMinutes: 60, Executor: ex}}
	}
	offering := func(ex ...string) func() (c machine.Ceiling) {
		return func() machine.Ceiling { c := ceiling(root); c.Executors = ex; return c }
	}
	cases := []struct {
		name, goos, executor string
		ceiling              func() machine.Ceiling
		want                 string // "" for inside
	}{
		{"me, with no executors listed (an older ceiling)", "linux", "me", offering(), ""},
		{"user, offered", "linux", "user", offering("user"), ""},
		{"confined, offered", "darwin", "confined", offering("me", "confined"), ""},
		{"user, not offered", "linux", "user", offering("me", "confined"), `executor "user" is not one this machine offers (me, confined)`},
		{"me on a dedicated-account machine", "linux", "me", offering("user"), `executor "me" is not one this machine offers (user)`},
		{"user on Windows", "windows", "user", offering("me", "user"), "current account only"},
		{"confined on Windows", "windows", "confined", offering("me", "confined"), "Linux and macOS only"},
		{"container with no image", "linux", "container", offering("me", "container"), "no image is named"},
		{"container on Windows", "windows", "container", offering("me", "container"), "Linux and macOS only"},
		{"no such executor", "linux", "root", offering("me"), "is not an executor"},
		{"none at all", "linux", "", offering("me"), "is not an executor"},
	}
	defer func(g string) { goos = g }(goos)
	for _, c := range cases {
		goos = c.goos
		err := runner(c.executor).Check(c.ceiling())
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: refused: %v", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}
}

// The runner's directory is checked against the ceiling's roots (#2630):
// the root and what is under it are inside; its parent, a sibling and a
// relative path are not, or a server could widen the ceiling the machine set.
func TestTheDirectoryMustBeAtOrBelowARoot(t *testing.T) {
	defer func(g string) { goos = g }(goos)
	goos = "linux"
	home := t.TempDir()
	root := filepath.Join(home, "dev")
	cases := []struct {
		name, dir string
		inside    bool
	}{
		{"the root itself", root, true},
		{"a child", filepath.Join(root, "repo"), true},
		{"a child whose name starts with ..", filepath.Join(root, "..cache"), true},
		{"the root's parent", home, false},
		{"the root's parent, written as root/..", root + string(filepath.Separator) + "..", false},
		{"the root's grandparent", filepath.Dir(home), false},
		{"a sibling", filepath.Join(home, "other"), false},
		{"a ..-prefixed relative path", filepath.Join("..", "dev", "repo"), false},
		{"a bare ..", "..", false},
	}
	for _, c := range cases {
		r := Runner{ID: 1, BoardID: 3, Config: Config{Agent: "claude", Directory: c.dir,
			PermissionMode: "default", TimeoutMinutes: 60, Executor: "me"}}
		err := r.Check(ceiling(root))
		switch {
		case c.inside && err != nil:
			t.Errorf("%s (%q): refused: %v", c.name, c.dir, err)
		case !c.inside && (err == nil || !strings.Contains(err.Error(), "is not inside")):
			t.Errorf("%s (%q): err = %v, want it refused as not inside %s", c.name, c.dir, err, root)
		}
	}
}
