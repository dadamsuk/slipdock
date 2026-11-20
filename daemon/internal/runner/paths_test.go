package runner

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// A card's paths (#3521): under confined and container, the only paths in
// its worktree the job may write.

func TestTheCardsPathsAreReadFromTheClaim(t *testing.T) {
	long := strings.Repeat("a", maxPathLength+1)
	many := "[" + strings.TrimSuffix(strings.Repeat(`"a",`, maxCardPaths+1), ",") + "]"
	cases := []struct {
		header string
		want   []string
		bad    bool
	}{
		{"", nil, false},
		{`["lib/**","docs/a.md"]`, []string{"lib/**", "docs/a.md"}, false},
		{`["docs/\u00e9.md"]`, []string{"docs/é.md"}, false},
		{`[]`, []string{}, false},
		{`lib/**`, nil, true},
		{`[1]`, nil, true},
		{`[""]`, nil, true},
		{`["` + long + `"]`, nil, true},
		{many, nil, true},
	}
	for _, c := range cases {
		h := http.Header{}
		h.Set("X-Job-Id", "5")
		if c.header != "" {
			h.Set("X-Card-Paths", c.header)
		}
		job, err := parseJob(h, nil)
		if err != nil || job.PathsBad != c.bad || strings.Join(job.Paths, "|") != strings.Join(c.want, "|") {
			t.Errorf("X-Card-Paths %.40q: paths %q bad %v err %v; want %q bad %v", c.header, job.Paths, job.PathsBad, err, c.want, c.bad)
		}
	}
}

func TestBracesExpandAsTheServersDo(t *testing.T) {
	got := expandBraces("docs/{manual,agents}.md")
	if strings.Join(got, " ") != "docs/manual.md docs/agents.md" {
		t.Fatalf("expandBraces = %q", got)
	}
	if got := expandBraces("{a,{b,c}}/x"); strings.Join(got, " ") != "a/x b/x a/x c/x" { // innermost first, as the server; repeats are dropped later
		t.Fatalf("nested: %q", got)
	}
	if got := expandBraces(strings.Repeat("{a,b,c,d}", 5)); len(got) != maxExpansions {
		t.Fatalf("at most %d expansions, got %d", maxExpansions, len(got))
	}
}

// laneDirs is a repository with a worktree of its own: the worktree, its
// git directory and the repository's, real paths.
func laneDirs(t *testing.T) (repo, root, gitDir, common string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	repo = realPath(t, t.TempDir())
	gitInit(t, repo)
	root = filepath.Join(realPath(t, t.TempDir()), "card-9")
	if out, err := exec.Command("git", "-C", repo, "worktree", "add", "-q", "-b", "card-9", root).CombinedOutput(); err != nil {
		t.Fatalf("worktree add: %v %s", err, out)
	}
	return repo, root, filepath.Join(repo, ".git", "worktrees", "card-9"), filepath.Join(repo, ".git")
}

func TestEachGlobGrantsItsDeepestFixedDirectory(t *testing.T) {
	repo, root, gitDir, common := laneDirs(t)
	for _, d := range []string{"lib/foo", "docs"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "a.md"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	outside := realPath(t, t.TempDir())
	if err := os.Symlink(outside, filepath.Join(root, "out")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(".git", filepath.Join(root, "dotgit")); err != nil {
		t.Fatal(err)
	}
	paths, notes, err := cardPaths(root, gitDir, common, []string{
		"lib/foo/**/*.ex",       // lib/foo
		"./docs/a.md",           // the file itself
		"docs/new/b.md",         // docs/new, made
		"test/{x,y}/*_test.exs", // test/x and test/y, made
		"/etc/passwd", "~/x", "a/../../b", ".git/hooks/*", "out/**", "dotgit", "c:/x",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		filepath.Join(root, "lib", "foo"), filepath.Join(root, "docs", "a.md"), filepath.Join(root, "docs", "new"),
		filepath.Join(root, "test", "x"), filepath.Join(root, "test", "y"),
		filepath.Join(common, "objects"), filepath.Join(common, "refs"), filepath.Join(common, "logs"), gitDir,
	}
	if strings.Join(paths, "\n") != strings.Join(want, "\n") {
		t.Fatalf("paths:\n%s\nwant:\n%s", strings.Join(paths, "\n"), strings.Join(want, "\n"))
	}
	for _, d := range []string{"docs/new", "test/x", "test/y"} {
		if fi, err := os.Stat(filepath.Join(root, d)); err != nil || !fi.IsDir() {
			t.Errorf("%s was made: %v", d, err)
		}
	}
	if len(notes) != 7 {
		t.Fatalf("a note for each glob that grants nothing, got:\n%s", strings.Join(notes, "\n"))
	}
	for _, p := range paths {
		if p == root || p == repo || p == common || strings.HasPrefix(p, outside) || strings.HasPrefix(p, filepath.Join(common, "hooks")) {
			t.Errorf("%s is writable", p)
		}
	}
}

func TestAGlobWithNoFixedDirectoryGrantsTheWholeWorktree(t *testing.T) {
	_, root, gitDir, common := laneDirs(t)
	for _, g := range []string{"*.md", "**/x.ex", "NEW.md", "."} {
		paths, _, err := cardPaths(root, gitDir, common, []string{g})
		if err != nil || len(paths) == 0 || paths[0] != root {
			t.Errorf("%q: %q %v; want the worktree first", g, paths, err)
		}
	}
}

func TestPathsNeedAWorktreeOfItsOwn(t *testing.T) {
	repo, _, _, common := laneDirs(t)
	if _, _, err := cardPaths(repo, common, common, []string{"lib/**"}); err == nil {
		t.Fatal("the repository itself (whose git directory is the whole .git) is refused")
	}
}

func TestTheWorktreesGitPointersArePutBack(t *testing.T) {
	_, root, gitDir, _ := laneDirs(t)
	commondir := filepath.Join(gitDir, "commondir")
	before, _ := os.ReadFile(commondir)
	dotgit, _ := os.ReadFile(filepath.Join(root, ".git"))
	pn := pin(root, gitDir)

	victim := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(victim, []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The job points commondir elsewhere, swaps the .git file for a link,
	// and adds config of its own.
	if err := os.WriteFile(commondir, []byte("/elsewhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, ".git")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, filepath.Join(root, ".git")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "config.worktree"), []byte("[core]\n\tfsmonitor = x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var notes []string
	pn.restore(func(s string) { notes = append(notes, s) })
	if got, _ := os.ReadFile(commondir); string(got) != string(before) {
		t.Errorf("commondir %q, want %q", got, before)
	}
	if fi, err := os.Lstat(filepath.Join(root, ".git")); err != nil || !fi.Mode().IsRegular() {
		t.Errorf(".git is a file again: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, ".git")); string(got) != string(dotgit) {
		t.Errorf(".git %q, want %q", got, dotgit)
	}
	if got, _ := os.ReadFile(victim); string(got) != "mine" {
		t.Errorf("putting .git back wrote through the link: %q", got)
	}
	if _, err := os.Lstat(filepath.Join(gitDir, "config.worktree")); err == nil {
		t.Error("config.worktree the job made is still there")
	}
	if len(notes) != 3 {
		t.Errorf("notes: %q", notes)
	}
	if out, err := exec.Command("git", "-C", root, "status", "--porcelain").CombinedOutput(); err != nil {
		t.Errorf("the worktree works again: %v %s", err, out)
	}

	// Nothing changed: nothing to say.
	notes = nil
	pin(root, gitDir).restore(func(s string) { notes = append(notes, s) })
	if len(notes) != 0 {
		t.Errorf("notes for an untouched worktree: %q", notes)
	}
}

// confinedRig is a worktree runner under confined, or a skip.
func confinedRig(t *testing.T) *rig {
	t.Helper()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	probe, _ := executor.New(executor.Confined, executor.Settings{GOOS: runtime.GOOS, Launcher: os.Args[0]})
	if err := probe.Ready(); err != nil {
		if os.Getenv("SLIPDOCK_EXECUTOR_TESTS") == "1" {
			t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but %v", err)
		}
		t.Skip(err)
	}
	r := newRig(t, Config{Worktree: "on", AfterHook: "after"})
	r.w.Runner.Config.Executor = executor.Confined
	gitInit(t, r.dir)
	return r
}

// tryScript tries each write in the job's worktree and says yes or no.
const tryScript = `
try() { if sh -c "$2" >/dev/null 2>&1; then echo "$1 yes"; else echo "$1 no"; fi; }
G=$(git rev-parse --path-format=absolute --git-dir)
C=$(git rev-parse --path-format=absolute --git-common-dir)
export G C
try path      'mkdir -p lib/a && echo x > lib/a/made.ex'
try commit    'git add lib/a/made.ex && git -c user.email=a@example.com -c user.name=a commit -qm made'
try top       'echo x > TOP.md'
try workflow  'mkdir -p .github/workflows && echo x > .github/workflows/x.yml'
try hooks     'echo x > "$C/hooks/pre-commit"'
try config    'echo x >> "$C/config"'
try dotgit    'echo x >> .git'
try checkout  'echo x > "$R/planted"'
try pointer   'echo /elsewhere > "$G/commondir"'
`

func TestAConfinedJobWritesOnlyItsCardsPathsInItsWorktree(t *testing.T) {
	r := confinedRig(t)
	hookOut := filepath.Join(r.dir, "hook.out")
	r.w.Local.Hooks = map[string]machine.Command{"after": {Path: "/bin/sh", Args: []string{"-c",
		`cat "$(git rev-parse --path-format=absolute --git-dir)/commondir" > ` + hookOut}}}
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c", strings.ReplaceAll(tryScript, "$R", r.dir), "sh"}}
	f := r.runJob(fakeJob{id: 310, kind: "claude", card: 9, prompt: "x", paths: `["lib/**","docs/x.md"]`})
	for _, want := range []string{"path yes", "commit yes", "top no", "workflow no", "hooks no", "config no",
		"dotgit no", "checkout no", "pointer yes"} {
		if !strings.Contains(f.body, want+"\n") {
			t.Errorf("want %q; the job said:\n%s", want, f.body)
		}
	}
	if !strings.Contains(f.body, "may write only its card's paths") || !strings.Contains(f.body, "which is put back") {
		t.Errorf("the log says what the job may write, and what was put back:\n%s", f.body)
	}
	if hooked, _ := os.ReadFile(hookOut); strings.Contains(string(hooked), "elsewhere") || len(hooked) == 0 {
		t.Errorf("the after hook read commondir %q: it is put back first", hooked)
	}
	out, err := exec.Command("git", "-C", r.dir, "log", "--name-only", "--format=", "card-9").CombinedOutput()
	if err != nil || !strings.Contains(string(out), "lib/a/made.ex") {
		t.Fatalf("the commit is on card-9: %s %v", out, err)
	}
	if _, err := os.Stat(filepath.Join(r.dir, ".git", "hooks", "pre-commit")); err == nil {
		t.Fatal("the job wrote the repository's hooks")
	}
}

func TestAConfinedJobWithNoPathsWritesItsWholeWorktree(t *testing.T) {
	r := confinedRig(t)
	r.w.Local.Hooks = map[string]machine.Command{"after": {Path: "/bin/sh", Args: []string{"-c", "true"}}}
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c", strings.ReplaceAll(tryScript, "$R", r.dir), "sh"}}
	for i, paths := range []string{"", "[]"} {
		f := r.runJob(fakeJob{id: 311 + int64(i), kind: "claude", card: int64(20 + i), prompt: "x", paths: paths})
		for _, want := range []string{"path yes", "commit yes", "top yes", "workflow yes", "hooks yes", "checkout yes"} {
			if !strings.Contains(f.body, want+"\n") {
				t.Errorf("paths %q: want %q (as before); the job said:\n%s", paths, want, f.body)
			}
		}
		if strings.Contains(f.body, "may write only") {
			t.Errorf("paths %q: kept to paths it doesn't have", paths)
		}
	}
}

func TestPathsTheRunnerCantReadRefuseAConfiningJob(t *testing.T) {
	r := confinedRig(t)
	r.w.Local.Hooks = map[string]machine.Command{"after": {Path: "/bin/sh", Args: []string{"-c", "true"}}}
	f := r.runJob(fakeJob{id: 315, kind: "claude", card: 9, prompt: "x", paths: `lib/**`})
	if f.exit == 0 || f.status != "failed" || !strings.Contains(f.body, "card paths this runner can't read") || r.agentSaw() != "" {
		t.Fatalf("finish = %+v; agent saw %q", f, r.agentSaw())
	}
}

func TestOnlyConfinedAndContainerKeepToPaths(t *testing.T) {
	var got []string
	for _, n := range executor.Names {
		if confinesPaths(n) {
			got = append(got, n)
		}
	}
	sort.Strings(got)
	if strings.Join(got, " ") != "confined container" {
		t.Fatalf("confinesPaths: %q", got)
	}
	// Under me, a job's paths change nothing it may write (or refuse it).
	r := newRig(t, Config{Worktree: "on"})
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	gitInit(t, r.dir)
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c", "echo x > TOP.md && echo wrote", "sh"}}
	f := r.runJob(fakeJob{id: 316, kind: "claude", card: 9, prompt: "x", paths: `bad`})
	if f.exit != 0 || !strings.Contains(f.body, "wrote") {
		t.Fatalf("finish = %+v", f)
	}
}

// TestAGlobThatClimbsOrNamesDotGitGrantsNothing: each refused glob says
// why, by its own guard (a .. is refused before it is cleaned away; .git
// before it is looked up).
func TestAGlobThatClimbsOrNamesDotGitGrantsNothing(t *testing.T) {
	_, root, gitDir, common := laneDirs(t)
	cases := map[string]string{
		"lib/../.github": "it has a ..",
		"a/../../x":      "it has a ..",
		"..":             "it has a ..",
		".git":           "the worktree's .git is never writable",
		".git/hooks":     "the worktree's .git is never writable",
		".git/hooks/*":   "the worktree's .git is never writable",
	}
	for glob, why := range cases {
		paths, notes, err := cardPaths(root, gitDir, common, []string{glob})
		if err != nil {
			t.Fatal(err)
		}
		want := fmt.Sprintf("the card's path %q grants nothing: %s", glob, why)
		if len(notes) != 1 || notes[0] != want {
			t.Errorf("%q: notes %q, want %q", glob, notes, want)
		}
		for _, p := range paths {
			if within(root, p) {
				t.Errorf("%q granted %s", glob, p)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(root, ".github")); err == nil {
		t.Error("a refused glob made a directory")
	}
}

// TestGitDirectoriesTheRunnerCantReadRefuseTheJob: keepToPaths needs both
// of git's answers, else the job isn't run.
func TestGitDirectoriesTheRunnerCantReadRefuseTheJob(t *testing.T) {
	ex, err := executor.New(executor.Confined, executor.Settings{GOOS: runtime.GOOS})
	if err != nil {
		t.Skip(err)
	}
	log, err := os.CreateTemp(t.TempDir(), "log")
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	for _, out := range []string{"", "/one/line\n", "/a\n/b\n/c\n"} {
		w := &Worker{Executor: ex, Exec: func(context.Context, string, string, ...string) (string, error) { return out, nil }}
		j := &jobRun{job: &Job{Paths: []string{"lib/**"}}, lane: &lane{path: t.TempDir()}, log: log}
		if paths, _, err := w.keepToPaths(context.Background(), j); err == nil || paths != nil ||
			!strings.Contains(err.Error(), "can't find the git directories") {
			t.Errorf("git said %q: %q %v", out, paths, err)
		}
	}
}
