package executor

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// aMachine is a home with every login in it, and the daemon's own
// directory where Linux keeps it (under the home's .config, beside the
// CLI's login): the machine key, a job's log and scratch directory, and
// the daemon's copy of the CLI. Every file says "secret" or "fine".
type aMachine struct {
	home, md, scratch, cli string
}

func newMachine(t *testing.T) aMachine {
	t.Helper()
	home, _ := filepath.EvalSymlinks(t.TempDir())
	m := aMachine{home: home, md: filepath.Join(home, ".config", "slipdock-runner", "machine")}
	m.scratch = filepath.Join(m.md, "jobs", "1", "tmp")
	m.cli = filepath.Join(m.md, "bin", "slipdock")
	files := map[string]string{
		".aws/credentials": "secret", ".netrc": "secret", ".docker/config.json": "secret",
		".kube/config": "secret", ".config/gcloud/credentials.db": "secret", ".azure/msal_token_cache.json": "secret",
		".gnupg/private-keys-v1.d/key":                "secret",
		".config/slipdock-runner/machine/machine-key": "secret", ".config/slipdock-runner/machine/identity": "secret",
		".config/slipdock-runner/machine/jobs/1/job.log": "secret",
		".config/slipdock-runner/machine/bin/slipdock":   "#!/bin/sh\necho fine\n",
		".ssh/id_ed25519": "fine", ".config/gh/hosts.yml": "fine", ".config/slipdock/config.json": "fine",
		".docker/cli-plugins/fine": "fine", ".gitconfig": "fine",
	}
	for name, body := range files {
		p := filepath.Join(home, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(m.scratch, 0o700); err != nil {
		t.Fatal(err)
	}
	return m
}

// settings are the worker's for a confined job on this machine.
func (m aMachine) settings(goos string) Settings {
	return Settings{GOOS: goos, Home: m.home, Launcher: os.Args[0],
		Protected: []string{m.md, filepath.Join(m.md, "jobs")}, Readable: []string{filepath.Dir(m.cli)}}
}

func TestTheConfineCommandLineNamesWhatAJobMayNotRead(t *testing.T) {
	defer func(f func() int) { landlockABI = f }(landlockABI)
	landlockABI = func() int { return 3 }
	m := newMachine(t)
	dir := t.TempDir()
	ex, _ := New(Confined, m.settings("linux"))
	cmd, err := ex.Command(Proc{Dir: dir, Scratch: m.scratch}, "/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	flag := func(name string) []string {
		var out []string
		for i, a := range cmd.Args {
			if a == name && i+1 < len(cmd.Args) {
				out = append(out, cmd.Args[i+1])
			}
		}
		return out
	}
	h := func(p string) string { return filepath.Join(m.home, filepath.FromSlash(p)) }
	deny := flag("--deny-read")
	want := []string{m.md, h(".aws"), h(".netrc"), h(".docker/config.json"), h(".kube"), h(".config/gcloud"),
		h(".azure"), h(".gnupg")}
	slices.Sort(want)
	if !slices.Equal(deny, want) {
		t.Fatalf("--deny-read\n got %v\nwant %v (the jobs' directory is inside the machine's)", deny, want)
	}
	read := flag("--read")
	for _, r := range []string{m.scratch, filepath.Dir(m.cli)} {
		if !slices.Contains(read, r) {
			t.Errorf("--read lacks %s: %v", r, read)
		}
	}
	for _, kept := range []string{h(".ssh"), h(".config/gh"), h(".config/slipdock"), h(".docker"), h(".config"), m.home} {
		if slices.Contains(deny, kept) || slices.Contains(read, kept) {
			t.Errorf("%s is the job's to read, and named: %v", kept, cmd.Args)
		}
	}
	if i, j := slices.Index(cmd.Args, "--deny-read"), slices.Index(cmd.Args, "--"); i < 0 || i > j {
		t.Fatalf("the limits come before the program: %v", cmd.Args)
	}

	// macOS: the same paths, in the sandbox profile.
	defer func(s string) { sandboxExec = s }(sandboxExec)
	sandboxExec = os.Args[0]
	ex, _ = New(Confined, m.settings("darwin"))
	cmd, err = ex.Command(Proc{Dir: dir, Scratch: m.scratch}, "/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	p := cmd.Args[2]
	allow := strings.Index(p, "(allow file-read-data")
	for _, d := range want {
		if i := strings.Index(p, "(subpath "+sbplString(d)+")"); i < 0 || i > allow {
			t.Errorf("the profile doesn't deny %s:\n%s", d, p)
		}
	}
	if !strings.Contains(p[allow:], sbplString(m.scratch)) || !strings.Contains(p[allow:], sbplString(filepath.Dir(m.cli))) {
		t.Errorf("the profile doesn't allow the scratch directory and the CLI:\n%s", p)
	}
}

func TestReadLimitsNeverAllowWhatHoldsADeniedPath(t *testing.T) {
	m := newMachine(t)
	ex, _ := New(Confined, m.settings("linux"))
	c := ex.(*confined)
	// The home holds the logins; .config the machine's directory: neither is
	// allowed, though a job may write them, nor is a denied path itself.
	deny, allow := c.readLimits(Proc{}, []string{m.home, filepath.Join(m.home, ".config"), m.scratch, "/elsewhere", "relative",
		m.md, filepath.Join(m.home, ".aws")})
	if !slices.Contains(deny, filepath.Join(m.home, ".aws")) || len(deny) != len(Unreadable)+1 {
		t.Fatalf("deny %v", deny)
	}
	if !slices.Equal(allow, []string{m.scratch, filepath.Dir(m.cli)}) {
		t.Fatalf("allow %v", allow)
	}
	// The job's own directory and repository stay readable wherever they
	// are, though under a card's paths it writes neither.
	work, repo := filepath.Join(m.md, "work"), filepath.Join(m.md, "repo")
	if _, allow := c.readLimits(Proc{Dir: work, Writable: []string{repo}}, nil); !slices.Contains(allow, work) || !slices.Contains(allow, repo) {
		t.Fatalf("the job's own paths: %v", allow)
	}
	// A launcher inside the daemon's directory stays readable: the job's
	// hook and its ssh run it.
	s := m.settings("linux")
	s.Launcher = filepath.Join(m.md, "bin", "slipdock-runner")
	s.Readable = nil
	ex, _ = New(Confined, s)
	if _, allow := ex.(*confined).readLimits(Proc{}, nil); !slices.Equal(allow, []string{s.Launcher}) {
		t.Fatalf("the launcher: %v", allow)
	}
	// Nothing to protect and no home: no read limits at all.
	ex, _ = New(Confined, Settings{GOOS: "linux", Launcher: os.Args[0]})
	if deny, allow := ex.(*confined).readLimits(Proc{Dir: m.home}, []string{m.home}); deny != nil || allow != nil {
		t.Fatalf("%v %v", deny, allow)
	}
}

func TestReadRulesCoverAllButTheDeniedPaths(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Landlock's rules: Unix paths")
	}
	m := newMachine(t)
	link := filepath.Join(m.home, "aws-link")
	if err := os.Symlink(filepath.Join(m.home, ".aws"), link); err != nil {
		t.Fatal(err)
	}
	h := func(p string) string { return filepath.Join(m.home, filepath.FromSlash(p)) }
	dirs, others := readRules([]string{h(".aws"), h(".docker/config.json"), m.md, h(".kube-not-there")})
	for _, d := range []string{"/", m.home, h(".docker"), h(".config"), h(".config/slipdock-runner")} {
		if !slices.Contains(dirs, d) {
			t.Errorf("%s may be listed: %v", d, dirs)
		}
	}
	for _, o := range []string{h(".ssh"), h(".config/gh"), h(".config/slipdock"), h(".docker/cli-plugins"), h(".netrc"), h(".gitconfig")} {
		if !slices.Contains(others, o) {
			t.Errorf("%s may be read: %v", o, others)
		}
	}
	for _, never := range []string{h(".aws"), h(".docker/config.json"), m.md, h(".kube-not-there"), link, m.home, h(".config")} {
		if slices.Contains(others, never) {
			t.Errorf("%s is read in full", never)
		}
	}
	for _, d := range dirs {
		if slices.Contains(others, d) || d == m.md || strings.HasPrefix(d, m.md+string(filepath.Separator)) {
			t.Errorf("%s twice, or inside a denied path", d)
		}
	}
}

func TestAWritablePathThatHoldsADeniedOneIsWrittenNotRead(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Landlock's rules: Unix paths")
	}
	m := newMachine(t)
	h := func(p string) string { return filepath.Join(m.home, filepath.FromSlash(p)) }
	elsewhere := t.TempDir()
	deny := []string{h(".aws"), m.md}
	handled, rules := pathRules(confinement{write: []string{m.home, h(".config"), m.scratch, elsewhere},
		deny: deny, read: []string{m.scratch, m.home, h(".config")}})
	reads := uint64(fsReadFile | fsReadDir)
	if handled != writeRights()|reads {
		t.Fatalf("handled %b", handled)
	}
	allowed := map[string][]uint64{}
	for _, r := range rules {
		allowed[r.path] = append(allowed[r.path], r.allowed)
		if r.allowed&fsReadFile != 0 && holdsAny(r.path, deny) {
			t.Errorf("%s holds a denied path and is read: %+v", r.path, r)
		}
	}
	// The write rules come first, in order: the home and .config, which
	// hold a denied path, are written, not read; the rest are read too.
	for i, want := range []pathRule{{path: m.home, allowed: writeRights()}, {path: h(".config"), allowed: writeRights()},
		{path: m.scratch, allowed: handled}, {path: elsewhere, allowed: handled}} {
		if i >= len(rules) || rules[i] != want {
			t.Fatalf("write rule %d: %+v, want %+v", i, rules[min(i, len(rules)-1)], want)
		}
	}
	// The home and .config are only listed beyond that: they are on the
	// way to a denied path.
	for _, path := range []string{m.home, h(".config")} {
		if got := allowed[path]; !slices.Equal(got, []uint64{writeRights(), fsReadDir}) {
			t.Errorf("%s: %b", path, got)
		}
	}
	if got := allowed[m.scratch]; !slices.Contains(got, reads) {
		t.Errorf("the scratch directory, inside a denied path: %b", got)
	}
	if got := allowed[h(".ssh")]; !slices.Equal(got, []uint64{reads}) {
		t.Errorf("~/.ssh: %b", got)
	}
	// Nothing denied: reads aren't handled, and no rule names them.
	handled, rules = pathRules(confinement{write: []string{m.home}, read: []string{m.scratch}})
	if handled != writeRights() {
		t.Fatalf("handled %b with nothing denied", handled)
	}
	for _, r := range rules {
		if r.allowed != writeRights() || r.path == m.scratch {
			t.Errorf("with nothing denied: %+v", r)
		}
	}
}

// TestAConfinedJobWithAWritableHomeStillCantReadItsDeniedPaths runs jobs
// under the real sandbox that may write the home, or the directory that
// holds the daemon's: they write there, and read what they need, not the
// rest.
func TestAConfinedJobWithAWritableHomeStillCantReadItsDeniedPaths(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	m := newMachine(t)
	ex, err := New(Confined, m.settings(runtime.GOOS))
	if err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err != nil {
		skipOrFail(t, err.Error())
	}
	script := `
try() { if sh -c "$2" >/dev/null 2>&1; then echo "$1 yes"; else echo "$1 no"; fi; }
try write    'echo fine > "$W/written" && test -s "$W/written"'
try aws      'cat "$H/.aws/credentials"'
try key      'cat "$H/.config/slipdock-runner/machine/machine-key"'
try ssh      'cat "$H/.ssh/id_ed25519"'
try gh       'cat "$H/.config/gh/hosts.yml"'
`
	for _, w := range []string{m.home, filepath.Join(m.home, ".config")} {
		cmd, err := ex.Command(Proc{Dir: t.TempDir(), Writable: []string{w}, Scratch: m.scratch,
			Env: []string{"H=" + m.home, "W=" + w}}, "/bin/sh", "-c", script)
		if err != nil {
			t.Fatal(err)
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		for _, want := range []string{"write yes", "aws no", "key no", "ssh yes", "gh yes"} {
			if !strings.Contains(string(out), want+"\n") {
				t.Errorf("writing %s: want %q; the job said:\n%s", w, want, out)
			}
		}
	}
}

// TestAConfinedJobCantReadTheMachineKeyOrTheLoginsNoJobNeeds runs a job
// under the real sandbox: it reads what it needs, not the rest.
func TestAConfinedJobCantReadTheMachineKeyOrTheLoginsNoJobNeeds(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	m := newMachine(t)
	ex, err := New(Confined, m.settings(runtime.GOOS))
	if err != nil {
		t.Fatal(err)
	}
	if err := ex.Ready(); err != nil {
		skipOrFail(t, err.Error())
	}
	git, _ := exec.LookPath("git")
	dir := t.TempDir()
	script := `
try() { if sh -c "$2" >/dev/null 2>&1; then echo "$1 yes"; else echo "$1 no"; fi; }
for f in .aws/credentials .netrc .docker/config.json .kube/config .config/gcloud/credentials.db \
    .azure/msal_token_cache.json .gnupg/private-keys-v1.d/key \
    .config/slipdock-runner/machine/machine-key .config/slipdock-runner/machine/identity \
    .config/slipdock-runner/machine/jobs/1/job.log \
    .ssh/id_ed25519 .config/gh/hosts.yml .config/slipdock/config.json .docker/cli-plugins/fine .gitconfig; do
  try "read $f" "cat '$H/$f'"
done
try "list-aws"    'ls "$H/.aws"'
try "list-home"   'ls "$H"'
try "scratch"     'echo fine > "$TMPDIR/s" && cat "$TMPDIR/s"'
try "dir"         'echo fine > "$D/f" && cat "$D/f"'
try "cli"         'test "$("$CLI")" = fine'
if [ -n "$GIT" ]; then
  try "git" '"$GIT" init -q "$D/g" && "$GIT" -C "$D/g" -c user.email=a@example.com -c user.name=a commit -q --allow-empty -m x && "$GIT" -C "$D/g" log --oneline'
fi
`
	cmd, err := ex.Command(Proc{Dir: dir, Scratch: m.scratch,
		Env: []string{"H=" + m.home, "D=" + dir, "CLI=" + m.cli, "GIT=" + git}}, "/bin/sh", "-c", script)
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	got := string(out)
	t.Logf("the job said:\n%s", got)
	wants := []string{"list-aws no", "list-home yes", "scratch yes", "dir yes", "cli yes"}
	for _, f := range []string{".aws/credentials", ".netrc", ".docker/config.json", ".kube/config", ".config/gcloud/credentials.db",
		".azure/msal_token_cache.json", ".gnupg/private-keys-v1.d/key", ".config/slipdock-runner/machine/machine-key",
		".config/slipdock-runner/machine/identity", ".config/slipdock-runner/machine/jobs/1/job.log"} {
		wants = append(wants, "read "+f+" no")
	}
	for _, f := range []string{".ssh/id_ed25519", ".config/gh/hosts.yml", ".config/slipdock/config.json", ".docker/cli-plugins/fine", ".gitconfig"} {
		wants = append(wants, "read "+f+" yes")
	}
	if git != "" {
		wants = append(wants, "git yes")
	}
	if runtime.GOOS == "linux" {
		// Landlock lets a directory on the way to a denied path be listed,
		// and what is beneath it with it: names, never contents.
		wants = slices.DeleteFunc(wants, func(s string) bool { return s == "list-aws no" })
	}
	for _, want := range wants {
		if !strings.Contains(got, want+"\n") {
			t.Errorf("want %q; the job said:\n%s", want, got)
		}
	}
}
