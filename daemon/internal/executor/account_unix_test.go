//go:build !windows

package executor

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestHomeClosed(t *testing.T) {
	home := t.TempDir()
	fi, _ := os.Stat(home)
	gid := int(fi.Sys().(*syscall.Stat_t).Gid)
	inGroup := func() ([]int, error) { return []int{4, gid}, nil }
	notInGroup := func() ([]int, error) { return []int{4}, nil }
	for _, c := range []struct {
		mode   os.FileMode
		groups func() ([]int, error)
		want   string
	}{
		{0o700, inGroup, ""},
		{0o750, notInGroup, ""},
		{0o750, inGroup, "open to its group"},
		{0o751, notInGroup, "open to every account"},
		{0o755, notInGroup, "chmod o-rwx " + home},
		{0o770, func() ([]int, error) { return nil, fmt.Errorf("no id") }, "no id"},
	} {
		if err := os.Chmod(home, c.mode); err != nil {
			t.Fatal(err)
		}
		err := homeClosed(home, "slipdock", c.groups)
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Errorf("mode %04o: %v, want %q", c.mode, err, c.want)
		}
	}
	if err := homeClosed(filepath.Join(home, "gone"), "slipdock", notInGroup); err == nil {
		t.Error("a home that isn't there")
	}

	_ = os.Chmod(home, 0o750)
	if HomeOpen("linux", home) || !HomeOpen("darwin", home) {
		t.Error("0750: closed on Linux, open on macOS, where every account is in the group")
	}
	_ = os.Chmod(home, 0o701)
	if !HomeOpen("linux", home) || HomeOpen("windows", home) {
		t.Error("0701 is open to all; Windows isn't asked")
	}
	_ = os.Chmod(home, 0o700)
	if HomeOpen("darwin", home) || HomeOpen("linux", filepath.Join(home, "gone")) {
		t.Error("0700 is closed")
	}
}

// TestTheUserExecutor sets an account up with init's own script and runs
// jobs as it: it needs sudo without a password and makes (then removes) an
// account, so it runs only where SLIPDOCK_EXECUTOR_TESTS=1 (CI's Linux
// daemon job). macOS's script is checked by TestAccountSetupScript only:
// making accounts on CI's Macs is slow and leaves them behind.
func TestTheUserExecutor(t *testing.T) {
	if !strict() || runtime.GOOS != "linux" {
		t.Skip("makes an account with sudo: SLIPDOCK_EXECUTOR_TESTS=1, on Linux")
	}
	if err := exec.Command("sudo", "-n", "true").Run(); err != nil {
		t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but sudo needs a password: %v", err)
	}
	owner := strings.TrimSpace(output(t, "id", "-un"))
	acct := fmt.Sprintf("sdtest%d", rand.New(rand.NewSource(time.Now().UnixNano())).Intn(1_000_000))

	// The owner's home: a directory of the owner's that any account can
	// reach (not the real home, which is left alone), with a secret in it.
	// It starts open, and the script closes it as init does.
	ownerHome, err := os.MkdirTemp("/tmp", "sdhome")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(ownerHome) })
	secret := filepath.Join(ownerHome, "secret")
	if err := os.WriteFile(secret, []byte("the owner's"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(ownerHome, 0o755); err != nil {
		t.Fatal(err)
	}

	open, err := AccountSetupScript("linux", acct, owner, ownerHome, false)
	if err != nil {
		t.Fatal(err)
	}
	script, _ := AccountSetupScript("linux", acct, owner, ownerHome, true)
	t.Cleanup(func() {
		_ = exec.Command("sudo", "-n", "rm", "-f", SudoersFile(acct)).Run()
		// The account's processes take a moment to go after the kill, and
		// userdel refuses while one is left.
		for i := 0; i < 50; i++ {
			_ = exec.Command("sudo", "-n", "pkill", "-KILL", "-u", acct).Run()
			_ = exec.Command("sudo", "-n", "userdel", "-r", acct).Run()
			if exec.Command("id", "-u", acct).Run() != nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Errorf("couldn't remove the account %s", acct)
	})
	out, err := exec.Command("sudo", "-n", "sh", "-c", open).CombinedOutput()
	if err != nil {
		t.Fatalf("the set-up script: %v\n%s", err, out)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	acctHome := lines[len(lines)-1]
	// While the home is open, the account reads it: else the refusal
	// below would prove nothing.
	if got, err := exec.Command("sudo", "-n", "-u", acct, "cat", secret).Output(); err != nil || string(got) != "the owner's" {
		t.Fatalf("an open home is readable by the account: %q %v", got, err)
	}
	// Run again, closing the home: an account already there is kept.
	if out, err := exec.Command("sudo", "-n", "sh", "-c", script).CombinedOutput(); err != nil {
		t.Fatalf("the set-up script again: %v\n%s", err, out)
	}
	if fi, err := os.Stat(ownerHome); err != nil || fi.Mode().Perm()&0o007 != 0 {
		t.Fatalf("the script closes the owner's home: %v %v", fi.Mode(), err)
	}

	t.Setenv("SLIPDOCK_TOKEN", "sdk_the_daemons_own")
	ex, err := New(User, Settings{GOOS: "linux", Home: ownerHome, Account: acct, AccountHome: acctHome, Getenv: os.Getenv})
	if err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err != nil {
		t.Fatalf("ready: %v", err)
	}
	work := filepath.Join(acctHome, "src")
	if _, err := ex.Exec(context.Background(), acctHome, "mkdir", "-p", work); err != nil {
		t.Fatal(err)
	}
	if !ex.IsDir(work) || ex.IsDir(filepath.Join(work, "gone")) {
		t.Fatal("IsDir as the account")
	}

	job := func(script string) (string, error) {
		cmd, err := ex.Command(Proc{Dir: work, Env: []string{"SLIPDOCK_JOB_ID=1"}}, "/bin/sh", "-c", script)
		if err != nil {
			t.Fatal(err)
		}
		out, err := cmd.CombinedOutput()
		return string(out), err
	}

	// It runs as the account, in its directory, with its own environment.
	got, err := job(`id -un; pwd; echo "home=$HOME"; env`)
	if err != nil {
		t.Fatalf("%v: %s", err, got)
	}
	for _, want := range []string{acct + "\n", work + "\n", "home=" + acctHome + "\n", "SLIPDOCK_JOB_ID=1\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("the job lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "sdk_the_daemons_own") {
		t.Fatal("the daemon's token reached the job")
	}

	// It can't read the owner's home.
	if got, err := job(`cat "` + secret + `"`); err == nil || strings.Contains(got, "the owner's") {
		t.Fatalf("the job read the owner's home: %q %v", got, err)
	}
	if got, err := job(`ls "` + ownerHome + `"`); err == nil {
		t.Fatalf("the job listed the owner's home: %q", got)
	}

	// The daemon reads the account's files as the account: its transcripts
	// are 0600.
	if _, err := job(`mkdir -p p/x && umask 077 && echo '{"card":1}' > p/x/t.jsonl && echo old > p/old.jsonl && touch -d '2 hours ago' p/old.jsonl`); err != nil {
		t.Fatal(err)
	}
	files := ex.Files()
	found := files.Glob(filepath.Join(work, "p"), filepath.Join("*", "*.jsonl"))
	if len(found) != 1 || found[0] != filepath.Join(work, "p", "x", "t.jsonl") {
		t.Fatalf("Glob: %v", found)
	}
	all := append(found, files.Glob(filepath.Join(work, "p"), "*.jsonl")...)
	recent := files.Recent(all, time.Now().Add(-time.Minute))
	if len(recent) != 1 || recent[0] != found[0] {
		t.Fatalf("Recent: %v from %v", recent, all)
	}
	if data, err := files.ReadFile(found[0]); err != nil || string(data) != "{\"card\":1}\n" {
		t.Fatalf("ReadFile: %q %v", data, err)
	}
	if _, err := os.ReadFile(found[0]); err == nil {
		t.Fatal("the daemon could read the account's 0600 file itself: the test proves nothing")
	}
	if p, err := ex.Resolve("sh"); err != nil || !filepath.IsAbs(p) {
		t.Fatalf("Resolve sh: %q %v", p, err)
	}
	if _, err := ex.Resolve("no-such-program-here"); err == nil {
		t.Fatal("Resolve finds what isn't there")
	}

	// Stopping: a job whose child ignores TERM is killed, child and all.
	tick := filepath.Join(work, "tick")
	cmd, _ := ex.Command(Proc{Dir: work}, "/bin/sh", "-c",
		`(trap "" TERM; while :; do date +%s%N > tick; sleep 0.05; done) & trap "" TERM; wait`)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	waitUntil(t, func() bool { _, err := files.ReadFile(tick); return err == nil })
	ex.Stop(cmd, false)
	time.Sleep(300 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("TERM stopped a job that ignores it: the test proves nothing")
	default:
	}
	ex.Stop(cmd, true)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the forced stop didn't end the job")
	}
	a, _ := files.ReadFile(tick)
	time.Sleep(300 * time.Millisecond)
	if b, _ := files.ReadFile(tick); string(a) != string(b) {
		t.Fatal("the job's child still ticks after the forced stop")
	}

	// A home open to the account refuses the job before it starts.
	if err := os.Chmod(ownerHome, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err == nil || !strings.Contains(err.Error(), "open to every account") {
		t.Fatalf("an open home: %v", err)
	}
}

func waitUntil(t *testing.T, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(50 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatal("timed out")
}

func output(t *testing.T, name string, args ...string) string {
	t.Helper()
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
