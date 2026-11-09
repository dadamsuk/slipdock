package executor

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestMain doubles as slipdock-runner's confine command, the launcher a
// confined job starts through on Linux.
func TestMain(m *testing.M) {
	if len(os.Args) >= 2 && os.Args[1] == "confine" {
		os.Exit(ConfineMain(os.Args[2:], os.Stderr))
	}
	os.Exit(m.Run())
}

// strict: on CI's executor jobs a missing facility is a failure, not a skip.
func strict() bool { return os.Getenv("SLIPDOCK_EXECUTOR_TESTS") == "1" }

func skipOrFail(t *testing.T, why string) {
	t.Helper()
	if strict() {
		t.Fatalf("SLIPDOCK_EXECUTOR_TESTS=1, but %s", why)
	}
	t.Skip(why)
}

func TestSupportedAndOffered(t *testing.T) {
	for _, c := range []struct{ name, goos, want string }{
		{Me, "windows", ""}, {Me, "linux", ""},
		{User, "linux", ""}, {User, "darwin", ""}, {User, "windows", "current account only"},
		{Confined, "linux", ""}, {Confined, "darwin", ""}, {Confined, "windows", "Linux and macOS only"},
		{Container, "linux", "not available on this daemon yet"},
		{"root", "linux", "is not an executor"}, {"", "linux", "is not an executor"},
	} {
		err := Supported(c.name, c.goos)
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Errorf("Supported(%q, %s) = %v, want %q", c.name, c.goos, err, c.want)
		}
	}
	for goos, want := range map[string]string{"windows": "me", "linux": "me,confined", "darwin": "me,confined"} {
		if got := strings.Join(Offered(goos, false), ","); got != want {
			t.Errorf("Offered(%s) = %s, want %s", goos, got, want)
		}
	}
	if got := strings.Join(Offered("linux", true), ","); got != "me,user,confined" {
		t.Errorf("with the account: %s", got)
	}
	if got := strings.Join(Offered("windows", true), ","); got != "me" {
		t.Errorf("Windows offers the current account only: %s", got)
	}
	for _, name := range Names {
		if Limits[name] == "" {
			t.Errorf("%s's limits aren't stated", name)
		}
	}
}

func TestNew(t *testing.T) {
	if _, err := New(User, Settings{GOOS: "linux"}); err == nil || !strings.Contains(err.Error(), "init --replace") {
		t.Fatalf("user with no account set up: %v", err)
	}
	if _, err := New(User, Settings{GOOS: "windows", Account: "slipdock"}); err == nil {
		t.Fatal("user on Windows")
	}
	if _, err := New(Container, Settings{GOOS: "linux"}); err == nil {
		t.Fatal("container")
	}
	for name, want := range map[string]string{Me: Me, User: User, Confined: Confined} {
		ex, err := New(name, Settings{GOOS: "linux", Account: "slipdock", AccountHome: "/srv/slipdock", Home: "/srv/me"})
		if err != nil || ex.Name() != want {
			t.Fatalf("New(%s) = %v, %v", name, ex, err)
		}
	}
	ex, _ := New(User, Settings{GOOS: "linux", Account: "slipdock", AccountHome: "/srv/slipdock", Home: "/srv/me"})
	if ex.Home() != "/srv/slipdock" {
		t.Fatalf("the user executor's home is the account's: %s", ex.Home())
	}
	ex, _ = New(Me, Settings{GOOS: "linux", Home: "/srv/me"})
	if ex.Home() != "/srv/me" {
		t.Fatal(ex.Home())
	}
}

func TestMeKeepsTheDaemonsEnvironmentButNotItsJobVariables(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	dir := t.TempDir()
	ex, _ := New(Me, Settings{GOOS: runtime.GOOS, Environ: func() []string {
		return []string{"KEEP=1", "SLIPDOCK_EXIT=7", "PWD=/elsewhere", "PATH=" + os.Getenv("PATH")}
	}})
	cmd, err := ex.Command(Proc{Dir: dir, Env: []string{"SLIPDOCK_JOB_ID=5"}}, "/bin/sh", "-c", "env")
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	env := "\n" + string(out)
	for _, want := range []string{"\nKEEP=1\n", "\nSLIPDOCK_JOB_ID=5\n", "\nPWD=" + dir + "\n"} {
		if !strings.Contains(env, want) {
			t.Errorf("missing %q in:%s", want, env)
		}
	}
	if strings.Contains(env, "SLIPDOCK_EXIT") || strings.Contains(env, "/elsewhere") {
		t.Errorf("the daemon's own job variables passed on:%s", env)
	}
	if cmd.SysProcAttr == nil {
		t.Error("a job starts in a process group of its own")
	}
	if _, err := ex.Resolve(filepath.Join(dir, "nothing")); err == nil {
		t.Error("a program that isn't there resolves")
	}
	if !ex.IsDir(dir) || ex.IsDir(filepath.Join(dir, "nothing")) {
		t.Error("IsDir")
	}
	if out, err := ex.Exec(context.Background(), dir, "/bin/sh", "-c", "pwd"); err != nil || !strings.Contains(out, filepath.Base(dir)) {
		t.Errorf("Exec runs in dir: %q %v", out, err)
	}
}

func TestSandboxProfile(t *testing.T) {
	p := SandboxProfile([]string{"/Users/me/src/repo", `/tmp/a "quoted" \ dir`})
	for _, want := range []string{
		"(allow default)", "(deny file-write*)",
		`(subpath "/Users/me/src/repo")`,
		`(subpath "/tmp/a \"quoted\" \\ dir")`,
		`(literal "/dev/null")`,
	} {
		if !strings.Contains(p, want) {
			t.Errorf("profile lacks %s:\n%s", want, p)
		}
	}
	if strings.Index(p, "(deny file-write*)") > strings.Index(p, "(allow file-write*") {
		t.Error("the allowances come after the denial, so they win")
	}
}

func TestJobProcesses(t *testing.T) {
	// sudo (100, root) -> monitor (101, root) -> agent (102, 1001, its own
	// group 102) -> child (103) and a grandchild that left its parent but
	// kept the group (104, parent 1). 105 is another job of the same
	// account; 106 another account's.
	ps := `  100     1   100     0
  101   100   101     0
  102   101   102  1001
  103   102   102  1001
  104     1   102  1001
  105     1   105  1001
  106   102   106  1002
  garbage`
	got := jobProcesses(ps, 100, 1001)
	if want := []int{102, 103, 104}; !sameInts(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := jobProcesses(ps, 999, 1001); len(got) != 0 {
		t.Fatalf("no such root: %v", got)
	}
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestAccountCommandLine(t *testing.T) {
	ex, _ := New(User, Settings{GOOS: "linux", Account: "slipdock", AccountHome: "/srv/slipdock", Home: "/srv/me",
		Getenv: func(k string) string { return map[string]string{"LANG": "C.UTF-8", "SLIPDOCK_TOKEN": "secret"}[k] }})
	cmd, err := ex.Command(Proc{Dir: "/srv/slipdock/src/repo", Env: []string{"SLIPDOCK_JOB_ID=9"}}, "/usr/bin/claude", "-p", "Build it")
	if err != nil {
		t.Fatal(err)
	}
	line := strings.Join(cmd.Args, " ")
	want := "sudo -n -u slipdock -- /usr/bin/env -i HOME=/srv/slipdock USER=slipdock LOGNAME=slipdock " +
		"PATH=/srv/slipdock/.local/bin:/srv/slipdock/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh LANG=C.UTF-8 " +
		"SLIPDOCK_JOB_ID=9 PWD=/srv/slipdock/src/repo /bin/sh -c " + inDir + " sh /srv/slipdock/src/repo /usr/bin/claude -p Build it"
	if line != want {
		t.Fatalf("command line\n got: %s\nwant: %s", line, want)
	}
	if cmd.Dir != "/" || strings.Contains(strings.Join(cmd.Env, " "), "secret") || strings.Contains(line, "secret") {
		t.Fatalf("nothing of the daemon's reaches the account: dir %s env %v", cmd.Dir, cmd.Env)
	}
	if cmd.SysProcAttr == nil {
		t.Error("in a process group of its own")
	}
	if !strings.Contains(DefaultPath("/Users/slipdock", "darwin"), "/opt/homebrew/bin") {
		t.Error("macOS's PATH has Homebrew")
	}
}

func TestAccountSetupScript(t *testing.T) {
	s, err := AccountSetupScript("linux", "slipdock", "builder", "/srv/builder", true)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"set -eu", "useradd --create-home", "if ! id -u slipdock",
		"'builder ALL=(slipdock) NOPASSWD: ALL'", "visudo -cf /etc/sudoers.d/slipdock-runner-slipdock.tmp",
		"mv /etc/sudoers.d/slipdock-runner-slipdock.tmp /etc/sudoers.d/slipdock-runner-slipdock",
		`chmod 0750 "$home"`, "chmod o-rwx '/srv/builder'"} {
		if !strings.Contains(s, want) {
			t.Errorf("linux script lacks %q:\n%s", want, s)
		}
	}
	if strings.Index(s, "visudo") > strings.Index(s, "mv /etc/sudoers.d") {
		t.Error("the rule is checked before it is put in place")
	}
	s, _ = AccountSetupScript("linux", "slipdock", "builder", "/srv/builder", false)
	if strings.Contains(s, "o-rwx") {
		t.Error("the home is only closed when asked")
	}
	s, _ = AccountSetupScript("darwin", "slipdock", "builder", "/Users/it's mine", true)
	for _, want := range []string{"sysadminctl -addUser slipdock", "createhomedir -c -u slipdock", "home=/Users/slipdock",
		`chmod go-rwx '/Users/it'\''s mine'`} {
		if !strings.Contains(s, want) {
			t.Errorf("macOS script lacks %q:\n%s", want, s)
		}
	}
	for _, c := range []struct{ goos, acct, owner, want string }{
		{"windows", "slipdock", "builder", "current account only"},
		{"linux", "Bad Name", "builder", "can't be the account's name"},
		{"linux", "slipdock;rm", "builder", "can't be the account's name"},
		{"linux", "slipdock", "root", "can't write a sudoers rule"},
		{"linux", "slipdock", "a b", "can't write a sudoers rule"},
		{"linux", "builder", "builder", "must not be you"},
	} {
		if _, err := AccountSetupScript(c.goos, c.acct, c.owner, "/srv/x", false); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%+v: %v", c, err)
		}
	}
}

func TestConfineMainRefusesABadCommandLine(t *testing.T) {
	var errs strings.Builder
	for _, args := range [][]string{{}, {"--write"}, {"--bogus"}, {"--write", "/tmp"}, {"--"}} {
		errs.Reset()
		if code := ConfineMain(args, &errs); code != 2 {
			t.Errorf("%v: exit %d (%s)", args, code, errs.String())
		}
	}
	if code := ConfineMain([]string{"--", "no-such-program-here"}, &errs); code != 127 {
		t.Errorf("a program that isn't there: %d", code)
	}
}

func TestConfinedIsntReadyWithoutWhatItNeeds(t *testing.T) {
	ex, _ := New(Confined, Settings{GOOS: "linux", Launcher: ""})
	err := ex.Ready()
	if err == nil {
		t.Fatal("confined with no launcher (or no Landlock) is ready")
	}
	if _, cerr := ex.Command(Proc{Dir: t.TempDir()}, "/bin/true"); cerr == nil {
		t.Fatal("a confined command was made that can't be confined: the job would run unconfined")
	}
	if runtime.GOOS == "linux" && landlockABI() >= 1 {
		if !strings.Contains(err.Error(), "can't find its own") {
			t.Fatalf("says why: %v", err)
		}
		ex, _ = New(Confined, Settings{GOOS: "linux", Launcher: filepath.Join(t.TempDir(), "gone")})
		if err := ex.Ready(); err == nil || !strings.Contains(err.Error(), "gone") {
			t.Fatalf("a launcher that isn't there: %v", err)
		}
	}
	if runtime.GOOS != "linux" && !strings.Contains(err.Error(), "Landlock") {
		t.Fatalf("no Landlock here: %v", err)
	}
	if _, err := New(Confined, Settings{GOOS: "freebsd"}); err == nil {
		t.Fatal("confined on another system")
	}
}

// confinedReady is a confined executor on this machine, or a skip.
func confinedReady(t *testing.T, writable ...string) Executor {
	t.Helper()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	ex, err := New(Confined, Settings{GOOS: runtime.GOOS, Launcher: os.Args[0], Writable: writable})
	if err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err != nil {
		skipOrFail(t, err.Error())
	}
	return ex
}

func TestAConfinedJobCantWriteOutsideItsDirectory(t *testing.T) {
	state := t.TempDir()
	ex := confinedReady(t, state, filepath.Join(t.TempDir(), "not-there"))
	dir, repo, scratch, outside := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
	keep := filepath.Join(outside, "keep")
	if err := os.WriteFile(keep, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	script := `
try() { if sh -c "$2" 2>/dev/null; then echo "$1 yes"; else echo "$1 no"; fi; }
try dir       'echo x > "$D/in.txt"'
try subdir    'mkdir -p "$D/a/b" && echo x > "$D/a/b/c"'
try repo      'echo x > "$R/commit"'
try scratch   'echo x > "$TMPDIR/s"'
try state     'echo x > "$S/session"'
try devnull   'echo x > /dev/null'
try outside   'echo x > "$O/new"'
try truncate  ': > "$O/keep"'
try remove    'rm -f "$O/keep"'
try mkdir     'mkdir "$O/d"'
try symlink   'ln -s /etc "$O/l"'
try move-out  'echo x > "$D/m" && mv "$D/m" "$O/m"'
try home      'echo x > "$H/.slipdock-confined-test"'
`
	cmd, err := ex.Command(Proc{Dir: dir, Writable: []string{repo}, Scratch: scratch,
		Env: []string{"D=" + dir, "R=" + repo, "S=" + state, "O=" + outside, "H=" + home}}, "/bin/sh", "-c", script)
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	t.Cleanup(func() { os.Remove(filepath.Join(home, ".slipdock-confined-test")) })
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	got := string(out)
	for _, want := range []string{"dir yes", "subdir yes", "repo yes", "scratch yes", "state yes", "devnull yes",
		"outside no", "truncate no", "remove no", "mkdir no", "symlink no", "move-out no", "home no"} {
		if !strings.Contains(got, want+"\n") {
			t.Errorf("want %q; the job said:\n%s", want, got)
		}
	}
	if data, err := os.ReadFile(keep); err != nil || string(data) != "x" {
		t.Fatalf("a file outside was changed: %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(home, ".slipdock-confined-test")); err == nil {
		t.Fatal("the job wrote to the home")
	}
}

func TestAConfinedJobCanStillBeStopped(t *testing.T) {
	ex := confinedReady(t)
	cmd, err := ex.Command(Proc{Dir: t.TempDir()}, "/bin/sh", "-c", `trap "" TERM; sleep 300 & wait`)
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	ex.Stop(cmd, true)
	if err := <-done; err == nil {
		t.Fatal("the job wasn't killed")
	}
}
