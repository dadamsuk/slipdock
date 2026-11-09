package runner

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestAJobWhoseExecutorCantRunFailsBeforeAnythingRuns(t *testing.T) {
	cases := []struct {
		name  string
		setup func(r *rig)
		want  string
	}{
		{"user, with no account set up", func(r *rig) { r.w.Runner.Config.Executor = executor.User; r.w.GOOS = "linux" },
			`executor "user": no dedicated account is set up`},
		{"confined, with no launcher", func(r *rig) {
			r.w.Runner.Config.Executor = executor.Confined
			r.w.GOOS = "linux"
			r.w.Launcher = filepath.Join(t.TempDir(), "gone")
		}, "executor confined: confined "},
		{"container", func(r *rig) { r.w.Runner.Config.Executor = executor.Container }, "not available on this daemon yet"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t, Config{BeforeHook: "setup"})
			r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup")}
			c.setup(r)
			f := r.runJob(fakeJob{id: 301, kind: "claude", card: 7, prompt: "x"})
			if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, c.want) || !strings.Contains(f.body, "so the job was not run") {
				t.Fatalf("finish = %+v, want 127 with %q", f, c.want)
			}
			if r.agentSaw() != "" || r.hooksRan() != "" {
				t.Fatal("something ran under an executor that can't run it")
			}
		})
	}
}

func TestAConfinedJobCantWriteOutsideItsDirectory(t *testing.T) {
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
	r := newRig(t, Config{AfterHook: "report"})
	r.w.Runner.Config.Executor = executor.Confined
	r.w.Local.Hooks = map[string]machine.Command{"report": self("hook", "report")}
	t.Setenv("HELPER_SCRATCH", "1")

	// The agent's report is outside the job's directory: it can't write it.
	f := r.runJob(fakeJob{id: 302, kind: "claude", card: 7, prompt: "x"})
	if f.exit != 0 || !strings.Contains(f.body, "hello from the agent") {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatalf("a confined agent wrote outside its directory:\n%s", r.agentSaw())
	}
	// Its hooks run (confined to the repository: they can't write their
	// report outside it either).
	if !strings.Contains(f.body, "hook report ran") || r.hooksRan() != "" {
		t.Fatalf("the after hook: log %q, wrote %q", f.body, r.hooksRan())
	}

	// What the local file lets it write, it can; and it has a scratch
	// directory of its own as TMPDIR.
	if err := os.WriteFile(r.out, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	r.w.Local.ConfinedWritable = []string{r.out}
	r.w.Executor = nil
	f = r.runJob(fakeJob{id: 303, kind: "claude", card: 7, prompt: "x"})
	saw := r.agentSaw()
	if f.exit != 0 || !strings.Contains(saw, "dir="+realPath(t, r.dir)) || !strings.Contains(saw, "scratch=writable") {
		t.Fatalf("finish %+v; the agent saw:\n%s", f, saw)
	}
	if _, err := os.Stat(filepath.Join(r.w.JobsDir, "11", "tmp", "scratch")); err != nil {
		t.Fatalf("the scratch directory is the runner's: %v", err)
	}
}

func TestAWorktreeJobUnderConfinedCommitsToItsRepository(t *testing.T) {
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
	r := newRig(t, Config{Worktree: "on"})
	r.w.Runner.Config.Executor = executor.Confined
	gitInit(t, r.dir)
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c",
		`echo x > made && git add made && git -c user.email=a@example.com -c user.name=a commit -qm made && echo committed`, "sh"}}
	f := r.runJob(fakeJob{id: 304, kind: "claude", card: 9, prompt: "x"})
	if f.exit != 0 || !strings.Contains(f.body, "committed") {
		t.Fatalf("a confined job in a worktree commits (its objects go to the repository): %+v", f)
	}
	out, err := exec.Command("git", "-C", r.dir, "log", "--oneline", "card-9").CombinedOutput()
	if err != nil || !strings.Contains(string(out), "made") {
		t.Fatalf("the commit is on card-9: %s %v", out, err)
	}
}

func gitInit(t *testing.T, dir string) {
	t.Helper()
	for _, args := range [][]string{{"init", "-q"}, {"-c", "user.email=a@example.com", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "start"}} {
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
}

// recorder is the me executor, with the home of another account, noting
// what the worker asks of it: everything a job does goes through it.
type recorder struct {
	executor.Executor
	home  string
	mu    sync.Mutex
	calls []string
}

func (r *recorder) note(s string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, s)
}

func (r *recorder) Home() string { return r.home }

func (r *recorder) Command(p executor.Proc, prog string, args ...string) (*exec.Cmd, error) {
	r.note("command " + filepath.Base(prog) + " " + strings.Join(args, " "))
	return r.Executor.Command(p, prog, args...)
}

func (r *recorder) Resolve(prog string) (string, error) {
	r.note("resolve " + filepath.Base(prog))
	return r.Executor.Resolve(prog)
}

func (r *recorder) IsDir(path string) bool {
	r.note("isdir")
	return r.Executor.IsDir(path)
}

func (r *recorder) Files() executor.Files { r.note("files"); return r.Executor.Files() }

func (r *recorder) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	r.note("exec " + name + " " + strings.Join(args, " "))
	return r.Executor.Exec(ctx, dir, name, args...)
}

func (r *recorder) Stop(cmd *exec.Cmd, force bool) {
	r.note(fmt.Sprintf("stop force=%v", force))
	r.Executor.Stop(cmd, force)
}

func (r *recorder) saw(prefix string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range r.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func TestEverythingAJobDoesGoesThroughItsExecutor(t *testing.T) {
	r := newRig(t, Config{BeforeHook: "setup"})
	r.w.Local.Hooks = map[string]machine.Command{"setup": self("hook", "setup")}
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	rec := &recorder{Executor: me, home: t.TempDir()}
	r.w.Executor = rec

	// The transcript and the skills are the executor's account's.
	url := "https://slipdock.example.com/boards/3/cards/42"
	t.Setenv("HELPER_TRANSCRIPT", filepath.Join(rec.home, ".claude", "projects", "p", "s.jsonl"))
	t.Setenv("HELPER_TRANSCRIPT_BODY", `{"u":"`+url+`"}`+"\n")
	skill := filepath.Join(rec.home, ".claude", "skills", "slipdock", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(skill), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skill, []byte("s"), 0o644); err != nil {
		t.Fatal(err)
	}

	f := r.runJob(fakeJob{id: 305, kind: "claude", card: 42, prompt: "x"})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	for _, want := range []string{"resolve ", "isdir", "command " + filepath.Base(os.Args[0]) + " helper hook setup",
		"command " + filepath.Base(os.Args[0]) + " helper agent", "files"} {
		if !rec.saw(want) {
			t.Errorf("the worker didn't ask the executor for %q: %v", want, rec.calls)
		}
	}
	if got := r.srv.transcript[305]; len(got) != 1 {
		t.Errorf("the transcript in the executor's home was sent: %q", got)
	}
	if got := r.srv.header(11).Get("X-Runner-Skills"); !strings.HasPrefix(got, "slipdock=") {
		t.Errorf("the skills in the executor's home are the ones reported: %q", got)
	}

	// Stopping goes through it too: asked, then made.
	r2, _ := treeRig(t, Config{})
	rec2 := &recorder{Executor: me, home: t.TempDir()}
	r2.w.Executor = rec2
	r2.w.Timeout = 300 * time.Millisecond
	if f := r2.runJob(fakeJob{id: 306, kind: "claude", card: 7, prompt: "x"}); f.status != "timeout" {
		t.Fatalf("finish = %+v", f)
	}
	if !rec2.saw("stop force=false") || !rec2.saw("stop force=true") {
		t.Fatalf("stopped through the executor: %v", rec2.calls)
	}
}

func TestTheMergesGitGoesThroughTheExecutor(t *testing.T) {
	r := newRig(t, Config{})
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	rec := &recorder{Executor: me, home: t.TempDir()}
	r.w.Executor = rec
	r.runJob(fakeJob{id: 307, kind: "merge", card: 7, pr: "https://github.com/example/repo/pull/1", sha: "abc1234"})
	if !rec.saw("exec git remote get-url origin") {
		t.Fatalf("the merge's git didn't go through the executor: %v", rec.calls)
	}
}

func TestCodeAConfinedJobPlantsInItsRepositoryStaysConfined(t *testing.T) {
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
	r := newRig(t, Config{Worktree: "on"})
	r.w.Runner.Config.Executor = executor.Confined
	gitInit(t, r.dir)
	top := realPath(t, r.dir)
	outside := t.TempDir()
	escaped, ran := filepath.Join(outside, "escaped"), filepath.Join(top, ".git", "ran")
	// The job, in its worktree, plants a fsmonitor and hooks in the
	// repository's .git, which it may write: each writes a mark outside
	// (and one inside, to show it ran).
	plant := `g=$(git rev-parse --git-common-dir) && g=$(cd "$g" && pwd) && ` +
		`printf '#!/bin/sh\necho "$0" >> %[1]q\necho "$0" >> %[2]q\nexit 0\n' > "$g/mon" && chmod +x "$g/mon" && ` +
		`for h in post-checkout reference-transaction post-index-change; do cp "$g/mon" "$g/hooks/$h"; done && ` +
		`git config core.fsmonitor "$g/mon" && echo planted`
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c", fmt.Sprintf(plant, escaped, ran), "sh"}}
	f := r.runJob(fakeJob{id: 308, kind: "claude", card: 9, prompt: "x"})
	if f.exit != 0 || !strings.Contains(f.body, "planted") {
		t.Fatalf("the job: %+v", f)
	}
	// The next job's worktree add (post-checkout, reference-transaction)
	// and its close (git status: the fsmonitor).
	r.w.Local.Agents["claude"] = machine.Command{Path: "/bin/sh", Args: []string{"-c", "git status --porcelain >/dev/null; echo next", "sh"}}
	if f := r.runJob(fakeJob{id: 309, kind: "claude", card: 10, prompt: "x"}); f.exit != 0 {
		t.Fatalf("the next job: %+v", f)
	}
	// And the merge's git.
	r.runJob(fakeJob{id: 310, kind: "merge", card: 10, pr: "https://github.com/example/repo/pull/1", sha: "abc1234"})

	data, err := os.ReadFile(ran)
	if err != nil || !strings.Contains(string(data), "mon") || !strings.Contains(string(data), "post-checkout") {
		t.Fatalf("the planted code ran (inside), else this proves nothing: %q %v", data, err)
	}
	if data, err := os.ReadFile(escaped); err == nil {
		t.Fatalf("code the job planted ran outside the sandbox, from the daemon's git or a hook:\n%s", data)
	}
}
