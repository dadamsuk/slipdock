package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

const theServersCLI = "#!/usr/bin/env escript\nthe server's CLI\n"

func sumOf(body string) string {
	s := sha256.Sum256([]byte(body))
	return hex.EncodeToString(s[:])
}

// serveCLI has the fake server serve body as its escript, and its sum.
func serveCLI(r *rig, body string) {
	r.srv.cli = []byte(body)
	r.srv.cliSums = []byte(sumOf(body) + "  slipdock.escript\n")
}

// personsCLI is a copy the person installed on the PATH, which the worker
// finds there.
func personsCLI(t *testing.T, r *rig, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "slipdock")
	writeFile(t, p, body)
	r.w.LookPath = func(name string) (string, error) {
		if name == "slipdock" {
			return p, nil
		}
		return "", os.ErrNotExist
	}
	return p
}

// daemonsBinOnly skips a test of the daemon's own bin on Windows, where
// only a cli local.json names is replaced (TestWhereTheCLIGoes).
func daemonsBinOnly(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("on Windows the daemon writes only a cli local.json names")
	}
}

// oldCLI is where a test's CLI is replaced: the daemon's bin, or on
// Windows a cli local.json names.
func oldCLI(t *testing.T, r *rig) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		r.w.Local.CLI = filepath.Join(t.TempDir(), "slipdock.escript")
		return r.w.Local.CLI
	}
	return r.w.daemonCLI()
}

func TestAnAgentJobPutsTheServersCLIInTheDaemonsBin(t *testing.T) {
	daemonsBinOnly(t)
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	theirs := personsCLI(t, r, "the person's old CLI\n")
	t.Setenv("HELPER_SHOW_PATH", "1")
	r.w.Getenv = func(k string) string {
		if k == "PATH" {
			return "/usr/bin"
		}
		return ""
	}

	if f := r.runJob(fakeJob{id: 801, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}

	bin := filepath.Join(filepath.Dir(r.w.JobsDir), "bin", "slipdock")
	if got := readFile(t, bin); got != theServersCLI {
		t.Fatalf("the daemon's bin has %q, want the server's CLI", got)
	}
	if runtime.GOOS != "windows" {
		if fi, _ := os.Stat(bin); fi.Mode().Perm()&0o100 == 0 {
			t.Errorf("the CLI isn't executable: %v", fi.Mode())
		}
	}
	if got := readFile(t, theirs); got != "the person's old CLI\n" {
		t.Errorf("the person's copy on the PATH was written: %q", got)
	}
	if _, err := os.Stat(bin + ".new"); !os.IsNotExist(err) {
		t.Errorf("the staged copy was left behind (%v)", err)
	}
	// The next claim reports the server's CLI, so its verdict is current.
	if got := r.w.cliPath(); got != bin {
		t.Errorf("the claim's CLI = %q, want the daemon's %q", got, bin)
	}
	if got := fileSHA(r.w.driftFiles(), r.w.cliPath()); got != sumOf(theServersCLI) {
		t.Errorf("the claim reports %s, want the server's %s", got, sumOf(theServersCLI))
	}
	// The agent of this very job finds the daemon's copy first.
	if !strings.Contains(r.agentSaw(), "env=PATH="+filepath.Dir(bin)+string(os.PathListSeparator)+"/usr/bin\n") {
		t.Errorf("the job's PATH doesn't start with the daemon's bin:\n%s", r.agentSaw())
	}
	if !strings.Contains(r.logged.String(), "cli: installed the server's CLI") {
		t.Errorf("the log doesn't say so:\n%s", r.logged)
	}
	for _, k := range r.srv.cliKeys {
		if k != "" {
			t.Errorf("the machine key went with a fetch anybody may make: %q", k)
		}
	}
}

func TestACurrentCLIIsNotFetchedAgain(t *testing.T) {
	daemonsBinOnly(t)
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	personsCLI(t, r, theServersCLI)

	if f := r.runJob(fakeJob{id: 802, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if r.srv.sumsGets != 1 || r.srv.cliGets != 0 {
		t.Errorf("sums fetched %d times, the CLI %d: want 1 and 0", r.srv.sumsGets, r.srv.cliGets)
	}
	if _, err := os.Stat(r.w.daemonCLI()); !os.IsNotExist(err) {
		t.Errorf("a current CLI was copied into the daemon's bin (%v)", err)
	}
}

func TestTheCLILocalJSONNamesIsReplacedInPlace(t *testing.T) {
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	named := filepath.Join(t.TempDir(), "tools", "slipdock")
	writeFile(t, named, "an old CLI\n")
	r.w.Local.CLI = named

	if f := r.runJob(fakeJob{id: 803, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if got := readFile(t, named); got != theServersCLI {
		t.Errorf("the named CLI = %q, want the server's", got)
	}
	if _, err := os.Stat(r.w.daemonCLI()); !os.IsNotExist(err) {
		t.Errorf("with cli named, the daemon's bin was written too (%v)", err)
	}
	if r.w.cliPath() != named {
		t.Errorf("the claim's CLI = %q, want the named %q", r.w.cliPath(), named)
	}
}

func TestAFailedFetchKeepsTheCLIAndTheJobRuns(t *testing.T) {
	for name, set := range map[string]func(*rig){
		"the escript fails": func(r *rig) { r.srv.cliCode = 500 },
		"no sums":           func(r *rig) { r.srv.cliSums = nil },
		"sums without the escript's line": func(r *rig) {
			r.srv.cliSums = []byte(sumOf("x") + "  something-else\n")
		},
		"sums over 4 KB": func(r *rig) {
			r.srv.cliSums = append(r.srv.cliSums, strings.Repeat("#", 4096)...)
		},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRig(t, Config{})
			serveCLI(r, theServersCLI)
			set(r)
			bin := oldCLI(t, r)
			writeFile(t, bin, "the daemon's old copy\n")

			if f := r.runJob(fakeJob{id: 804, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
				t.Fatalf("a failed CLI update failed the job: %+v", f)
			}
			if got := readFile(t, bin); got != "the daemon's old copy\n" {
				t.Errorf("the CLI = %q, want the old one kept", got)
			}
			if !strings.Contains(r.logged.String(), "keeping the CLI there is") || strings.Contains(r.logged.String(), "SHA-256") {
				t.Errorf("the log doesn't say the CLI was kept:\n%s", r.logged)
			}
			if !strings.Contains(r.agentSaw(), "dir=") {
				t.Errorf("the agent didn't run")
			}
		})
	}
}

// fetch reads at most max bytes: a body over it is refused, not cut short.
func TestFetchRefusesABodyOverItsMax(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.cliSums = []byte("0123456789")
	for max, want := range map[int]string{10: "", 11: "", 9: "over 9 bytes", 1: "over 1 bytes"} {
		data, err := r.w.Client.fetch(context.Background(), cliSumsPath, max)
		switch {
		case want == "" && (err != nil || string(data) != "0123456789"):
			t.Errorf("max %d: got %q, %v; want the whole body", max, data, err)
		case want != "" && (err == nil || err.Error() != want || data != nil):
			t.Errorf("max %d: got %q, %v; want the error %q", max, data, err, want)
		}
	}
}

// An escript over 64 MB is refused even when its sum matches.
func TestAnEscriptOver64MBKeepsTheCLI(t *testing.T) {
	if cliMax != 64<<20 {
		t.Fatalf("cliMax = %d, want 64 MB", cliMax)
	}
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI+strings.Repeat("#", cliMax+1-len(theServersCLI)))
	bin := oldCLI(t, r)
	writeFile(t, bin, "the daemon's old copy\n")

	if f := r.runJob(fakeJob{id: 806, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("an oversize CLI failed the job: %+v", f)
	}
	if got := readFile(t, bin); got != "the daemon's old copy\n" {
		t.Errorf("the CLI was replaced by one over 64 MB")
	}
	if !strings.Contains(r.logged.String(), "over 67108864 bytes") {
		t.Errorf("the log doesn't say why:\n%s", r.logged)
	}
}

func TestAWrongSumKeepsTheCLI(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.cli = []byte("a CLI cut short in transit\n")
	r.srv.cliSums = []byte(sumOf(theServersCLI) + "  slipdock.escript\n")
	bin := oldCLI(t, r)
	writeFile(t, bin, "the daemon's old copy\n")

	if f := r.runJob(fakeJob{id: 805, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if got := readFile(t, bin); got != "the daemon's old copy\n" {
		t.Errorf("the CLI = %q, want the old one kept", got)
	}
	if _, err := os.Stat(bin + ".new"); !os.IsNotExist(err) {
		t.Errorf("a download with the wrong sum was written (%v)", err)
	}
	if !strings.Contains(r.logged.String(), "not the "+sumOf(theServersCLI)) {
		t.Errorf("the log doesn't name the mismatch:\n%s", r.logged)
	}
}

func TestAWrongSumWithNoCLIWritesNone(t *testing.T) {
	daemonsBinOnly(t)
	r := newRig(t, Config{})
	r.srv.cli = []byte("not the server's\n")
	r.srv.cliSums = []byte(sumOf(theServersCLI) + "  slipdock.escript\n")

	if f := r.runJob(fakeJob{id: 806, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if _, err := os.Stat(r.w.daemonCLI()); !os.IsNotExist(err) {
		t.Errorf("a CLI with the wrong sum was installed (%v)", err)
	}
	if r.w.cliPath() != "" {
		t.Errorf("the claim reports %q, want no CLI", r.w.cliPath())
	}
}

func TestLocalJSONTurnsTheCLIUpdateOff(t *testing.T) {
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	r.w.Local.NoCLIUpdate = true
	theirs := personsCLI(t, r, "the person's CLI\n")
	// A copy the daemon put in its bin before the switch went off is
	// neither used nor reported.
	writeFile(t, r.w.daemonCLI(), "the daemon's earlier copy\n")
	t.Setenv("HELPER_SHOW_PATH", "1")

	if f := r.runJob(fakeJob{id: 807, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if r.srv.sumsGets != 0 || r.srv.cliGets != 0 {
		t.Errorf("no_cli_update fetched: sums %d, CLI %d", r.srv.sumsGets, r.srv.cliGets)
	}
	if got := readFile(t, r.w.daemonCLI()); got != "the daemon's earlier copy\n" {
		t.Errorf("the daemon's copy = %q", got)
	}
	if r.w.cliPath() != theirs {
		t.Errorf("the claim's CLI = %q, want the person's %q", r.w.cliPath(), theirs)
	}
	if strings.Contains(r.agentSaw(), "env=PATH="+filepath.Dir(r.w.daemonCLI())) {
		t.Errorf("the daemon's bin is on the job's PATH with the update off:\n%s", r.agentSaw())
	}
}

func TestAMergeAndAProbeDontUpdateTheCLI(t *testing.T) {
	for _, kind := range []string{"merge", ProbeKind} {
		t.Run(kind, func(t *testing.T) {
			r := newRig(t, Config{})
			serveCLI(r, theServersCLI)
			r.w.Exec = (&fakeGit{}).exec
			r.runJob(fakeJob{id: 808, kind: kind, card: 42, prompt: "probe\nskills: current\ncli: old\n",
				pr: "https://github.com/example/repo/pull/1", sha: strings.Repeat("a", 40)})
			if r.srv.sumsGets != 0 || r.srv.cliGets != 0 {
				t.Errorf("a %s job fetched: sums %d, CLI %d", kind, r.srv.sumsGets, r.srv.cliGets)
			}
			if _, err := os.Stat(r.w.daemonCLI()); !os.IsNotExist(err) {
				t.Errorf("a %s job installed the CLI (%v)", kind, err)
			}
		})
	}
}

func TestUnderTheUserExecutorTheAccountsCLIIsLeftAlone(t *testing.T) {
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	r.w.Executor = asAccount{&recorder{Executor: me, home: t.TempDir()}}
	r.w.Local.CLI = filepath.Join(t.TempDir(), "slipdock")

	if f := r.runJob(fakeJob{id: 809, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if r.srv.sumsGets != 0 || r.srv.cliGets != 0 {
		t.Errorf("the CLI was fetched for an account the daemon can't write for")
	}
	if !strings.Contains(r.logged.String(), "cli: the jobs run as another account") {
		t.Errorf("the log says why the CLI was left:\n%s", r.logged)
	}
}

func TestASymlinkedCLIIsLeftAlone(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	checkout := filepath.Join(t.TempDir(), "slipdock")
	writeFile(t, checkout, "a build from a checkout\n")
	link := filepath.Join(t.TempDir(), "slipdock")
	if err := os.Symlink(checkout, link); err != nil {
		t.Fatal(err)
	}
	r.w.Local.CLI = link

	if f := r.runJob(fakeJob{id: 810, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if fi, err := os.Lstat(link); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the symlink was replaced (%v)", err)
	}
	if got := readFile(t, checkout); got != "a build from a checkout\n" {
		t.Errorf("the checkout's build = %q", got)
	}
	if !strings.Contains(r.logged.String(), "is a symlink; left alone") {
		t.Errorf("the log doesn't say so:\n%s", r.logged)
	}
}

func TestACLIThatCantBeWrittenKeepsTheOldOne(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("folder permissions differ on Windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	r := newRig(t, Config{})
	serveCLI(r, theServersCLI)
	dir := filepath.Join(t.TempDir(), "ro")
	named := filepath.Join(dir, "slipdock")
	writeFile(t, named, "an old CLI\n")
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	r.w.Local.CLI = named

	if f := r.runJob(fakeJob{id: 811, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if got := readFile(t, named); got != "an old CLI\n" {
		t.Errorf("the CLI = %q, want the old one kept", got)
	}
	if !strings.Contains(r.logged.String(), "could not put the server's CLI") {
		t.Errorf("the log doesn't say so:\n%s", r.logged)
	}
}

func TestWhereTheCLIGoes(t *testing.T) {
	jobs := filepath.Join("m", "jobs")
	daemons := filepath.Join("m", "bin", "slipdock")
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	ct := named{me, executor.Container}
	for _, c := range []struct {
		name   string
		w      Worker
		want   string
		whyHas string
	}{
		{"the daemon's bin", Worker{JobsDir: jobs, GOOS: "linux", Executor: me}, daemons, ""},
		{"its machine dir", Worker{JobsDir: jobs, MachineDir: "md", GOOS: "darwin", Executor: me}, filepath.Join("md", "bin", "slipdock"), ""},
		{"windows", Worker{JobsDir: jobs, GOOS: "windows", Executor: me}, "", "/cli/install.ps1"},
		{"windows, named", Worker{JobsDir: jobs, GOOS: "windows", Executor: me, Local: localCLI("C:/x/slipdock.escript")}, "C:/x/slipdock.escript", ""},
		{"a container", Worker{JobsDir: jobs, GOOS: "linux", Executor: ct}, "", "container"},
		{"a container, named", Worker{JobsDir: jobs, GOOS: "linux", Executor: ct, Local: localCLI("/opt/slipdock")}, "/opt/slipdock", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, why := c.w.cliTarget()
			if got != c.want || (c.whyHas == "") != (why == "") || !strings.Contains(why, c.whyHas) {
				t.Errorf("cliTarget = %q, %q; want %q, a why with %q", got, why, c.want, c.whyHas)
			}
		})
	}
}

func TestTheSumIsReadFromSHA256SUMS(t *testing.T) {
	s := sumOf("x")
	for body, want := range map[string]string{
		s + "  slipdock.escript\n":                          s,
		s + " *slipdock.escript\r\n":                        s,
		sumOf("y") + "  other\n" + s + "  slipdock.escript": s,
		s + "  slipdock.escript.old\n":                      "",
		strings.ToUpper(s) + "  slipdock.escript\n":         "",
	} {
		r := newRig(t, Config{})
		r.srv.cliSums = []byte(body)
		got, err := r.w.Client.serverCLISum(context.Background())
		if got != want || (want == "") != (err != nil) {
			t.Errorf("sum of %q = %q, %v; want %q", body, got, err, want)
		}
	}
}

// named is an executor that says it is another.
type named struct {
	executor.Executor
	name string
}

func (n named) Name() string { return n.name }

func localCLI(p string) (l machine.Local) {
	l.CLI = p
	return l
}
