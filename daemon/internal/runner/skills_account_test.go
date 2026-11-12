//go:build !windows

package runner

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// feedingAccount is the user executor as keepSkills sees it: it says it is
// the user executor, and its Feed runs the command here (as the account's
// sudo would there), or fails as fail says.
type feedingAccount struct {
	*recorder
	fed   [][]string
	stdin [][]byte
	fail  func(ctx context.Context, stdin []byte) (string, error)
}

func (*feedingAccount) Name() string { return executor.User }

func (f *feedingAccount) Feed(ctx context.Context, stdin []byte, name string, args ...string) (string, error) {
	f.fed = append(f.fed, append([]string{name}, args...))
	f.stdin = append(f.stdin, stdin)
	if f.fail != nil {
		return f.fail(ctx, stdin)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = bytes.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func accountRig(t *testing.T) (*rig, *feedingAccount) {
	t.Helper()
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	acct := &feedingAccount{recorder: &recorder{Executor: me, home: t.TempDir()}}
	r.w.Executor = acct
	return r, acct
}

func TestUnderTheUserExecutorTheAccountUnpacksTheServersSkills(t *testing.T) {
	r, acct := accountRig(t)
	dir := filepath.Join(acct.home, ".claude", "skills")
	writeFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md"), "a stale loop\n")
	writeFile(t, filepath.Join(dir, "slipdock-loop", "gone.md"), "a file the server no longer ships\n")
	writeFile(t, filepath.Join(dir, "other-skill", "SKILL.md"), "not ours\n")
	writeFile(t, filepath.Join(dir, "slipdock-loop.new", "stale.md"), "a half-done earlier swap\n")

	if f := r.runJob(fakeJob{id: 720, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}

	if len(acct.fed) != 1 {
		t.Fatalf("Feed ran %d times, want once", len(acct.fed))
	}
	if got, want := acct.fed[0][0:2], []string{"/bin/sh", "-c"}; !reflect.DeepEqual(got, want) {
		t.Errorf("fed %v, want a shell", got)
	}
	if got, want := acct.fed[0][3:], []string{"sh", dir, "slipdock", "slipdock-loop", "slipdock-wiki"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the script's arguments = %v, want %v", got, want)
	}
	for p, want := range map[string]string{
		"slipdock/SKILL.md":               "the server's slipdock\n",
		"slipdock-loop/SKILL.md":          "the server's loop\n",
		"slipdock-wiki/references/api.md": "api\n",
		"other-skill/SKILL.md":            "not ours\n",
	} {
		if got := readFile(t, filepath.Join(dir, filepath.FromSlash(p))); got != want {
			t.Errorf("%s = %q, want %q", p, got, want)
		}
	}
	for _, gone := range []string{"slipdock-loop/gone.md", "slipdock-loop/stale.md", "slipdock-loop.new", "slipdock.new"} {
		if _, err := os.Stat(filepath.Join(dir, gone)); !os.IsNotExist(err) {
			t.Errorf("%s is still there (%v)", gone, err)
		}
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".slipdock-skills.*")); len(left) != 0 {
		t.Errorf("the staging folder was left behind: %v", left)
	}
	if !strings.Contains(r.logged.String(), "skills: installed the server's slipdock slipdock-loop slipdock-wiki (signed with the release key) in "+dir) {
		t.Errorf("the daemon's log says what it installed:\n%s", r.logged)
	}
	if !strings.Contains(r.srv.finishes[720].body, "skills: installed the server's") {
		t.Errorf("the job's log says so too: %q", r.srv.finishes[720].body)
	}
}

func TestTheAccountIsFedOnlyTheCheckedEntries(t *testing.T) {
	skills, err := readSkills(tarGz(t,
		entry{name: "./slipdock/", typ: '5'},
		entry{name: "./slipdock/SKILL.md", body: "s"},
		entry{name: "slipdock-wiki/references/deep/api.md", body: "api"},
		entry{name: "slipdock-empty/", typ: '5'},
	))
	if err != nil {
		t.Fatal(err)
	}
	packed, err := packSkills([]string{"slipdock", "slipdock-empty", "slipdock-wiki"}, skills)
	if err != nil {
		t.Fatal(err)
	}
	var gz bytes.Buffer
	w := gzip.NewWriter(&gz)
	_, _ = w.Write(packed)
	_ = w.Close()
	again, err := readSkills(gz.Bytes())
	if err != nil {
		t.Fatalf("what the account is fed doesn't pass the same checks: %v", err)
	}
	if !reflect.DeepEqual(again, skills) {
		t.Errorf("fed %+v, want the checked %+v", again, skills)
	}
}

func TestUnderTheUserExecutorASymlinkedSkillIsLeftAlone(t *testing.T) {
	r, acct := accountRig(t)
	dir := filepath.Join(acct.home, ".claude", "skills")
	checkout := filepath.Join(t.TempDir(), "slipdock-loop")
	writeFile(t, filepath.Join(checkout, "SKILL.md"), "my working copy\n")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(checkout, filepath.Join(dir, "slipdock-loop")); err != nil {
		t.Fatal(err)
	}

	if f := r.runJob(fakeJob{id: 721, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if fi, err := os.Lstat(filepath.Join(dir, "slipdock-loop")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the symlink was replaced (%v, %v)", fi, err)
	}
	if got := readFile(t, filepath.Join(checkout, "SKILL.md")); got != "my working copy\n" {
		t.Errorf("the symlink's target was written: %q", got)
	}
	if got := readFile(t, filepath.Join(dir, "slipdock", "SKILL.md")); got != "the server's slipdock\n" {
		t.Errorf("the other skills are still installed: %q", got)
	}
	log := r.logged.String()
	if !strings.Contains(log, filepath.Join(dir, "slipdock-loop")+" is a symlink; left alone") {
		t.Errorf("the log says it was left alone:\n%s", log)
	}
	if !strings.Contains(log, "installed the server's slipdock slipdock-wiki (signed with the release key) in") {
		t.Errorf("the log names only the skills put in place:\n%s", log)
	}
}

func TestUnderTheUserExecutorAFailedUnpackKeepsTheSkillsAndTheJobRuns(t *testing.T) {
	type feed = func(context.Context, []byte) (string, error)
	cases := []struct {
		name string
		fail func(dir string) feed
		says string
	}{
		{"sudo refused", func(string) feed {
			return func(context.Context, []byte) (string, error) {
				return "sudo: a password is required\n", errors.New("exit status 1")
			}
		}, "could not unpack the server's skills as the account (exit status 1: sudo: a password is required)"},
		{"no output", func(string) feed {
			return func(context.Context, []byte) (string, error) { return "", errors.New("signal: killed") }
		}, "could not unpack the server's skills as the account (signal: killed)"},
		{"tar failed", func(dir string) feed {
			// The real script, fed something that isn't a tar.
			return func(ctx context.Context, _ []byte) (string, error) {
				cmd := exec.CommandContext(ctx, "/bin/sh", "-c", putSkillsScript, "sh", dir, "slipdock-loop")
				cmd.Stdin = strings.NewReader("not a tar")
				out, err := cmd.CombinedOutput()
				return string(out), err
			}
		}, "could not unpack the server's skills as the account (exit status 4"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, acct := accountRig(t)
			dir := filepath.Join(acct.home, ".claude", "skills")
			writeFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md"), "installed loop\n")
			acct.fail = c.fail(dir)

			if f := r.runJob(fakeJob{id: 722, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
				t.Fatalf("the job runs: finish = %+v", f)
			}
			if got := readFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md")); got != "installed loop\n" {
				t.Errorf("the installed copy = %q, want it kept", got)
			}
			log := r.logged.String()
			if !strings.Contains(log, "skills: "+c.says) || !strings.Contains(log, "keeping the installed skills in "+dir) {
				t.Errorf("the log says %q:\n%s", c.says, log)
			}
			if strings.Contains(log, "installed the server's") {
				t.Errorf("nothing is named as installed:\n%s", log)
			}
			if !strings.Contains(r.srv.finishes[722].body, "skills: could not unpack") {
				t.Errorf("the job's log says so too: %q", r.srv.finishes[722].body)
			}
			if left, _ := filepath.Glob(filepath.Join(dir, ".slipdock-skills.*")); len(left) != 0 {
				t.Errorf("the staging folder was left behind: %v", left)
			}
		})
	}
}

func TestUnderTheUserExecutorABadArchiveIsNeverFed(t *testing.T) {
	r, acct := accountRig(t)
	r.srv.skills = tarGz(t, entry{name: "slipdock/SKILL.md", body: "x"}, entry{name: "slipdock/evil", typ: '2', link: "/etc/passwd"})

	if f := r.runJob(fakeJob{id: 723, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if len(acct.fed) != 0 {
		t.Errorf("the account was fed a refused archive: %v", acct.fed)
	}
	if !strings.Contains(r.logged.String(), "not a file or folder") {
		t.Errorf("the log says why it was refused:\n%s", r.logged)
	}
}

func TestUnderTheUserExecutorASkillThatCantBePutInPlaceKeepsItsCopy(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	dir := t.TempDir()
	stuck := filepath.Join(dir, "slipdock-loop.new")
	writeFile(t, filepath.Join(stuck, "x"), "x")
	if err := os.Chmod(stuck, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(stuck, 0o700) })
	writeFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md"), "installed loop")
	skills, err := readSkills(serverSkills(t))
	if err != nil {
		t.Fatal(err)
	}
	acct := &feedingAccount{}

	put, notes := putSkillsAs(context.Background(), acct, dir, skills)
	if strings.Join(put, " ") != "slipdock slipdock-wiki" {
		t.Errorf("put = %v", put)
	}
	var failed bool
	for _, n := range notes {
		if strings.Contains(n, "could not put slipdock-loop in place as the account") {
			failed = true
		}
	}
	if !failed {
		t.Errorf("notes = %v", notes)
	}
	if got := readFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md")); got != "installed loop" {
		t.Errorf("the installed copy = %q, want it kept", got)
	}
}

func TestOnlyTheSkillsFedAreReportedFromTheAccountsOutput(t *testing.T) {
	skills, err := readSkills(serverSkills(t))
	if err != nil {
		t.Fatal(err)
	}
	acct := &feedingAccount{fail: func(context.Context, []byte) (string, error) {
		return "put slipdock\nput not-fed\nlink also-not-fed\nfail slipdock-wiki\nsome noise\n", nil
	}}
	put, notes := putSkillsAs(context.Background(), acct, "/skills", skills)
	if strings.Join(put, " ") != "slipdock" {
		t.Errorf("put = %v, want only the fed skill it put", put)
	}
	want := []string{
		"could not put slipdock-wiki in place as the account; kept the installed copy",
		"the account said: put not-fed; link also-not-fed; some noise",
	}
	if !reflect.DeepEqual(notes, want) {
		t.Errorf("notes = %q, want %q", notes, want)
	}
}
