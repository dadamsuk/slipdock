package runner

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// entry is one entry of a test archive: a file unless typ says otherwise.
type entry struct {
	name, body string
	typ        byte
	link       string
}

func tarGz(t *testing.T, entries ...entry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		typ := e.typ
		if typ == 0 {
			typ = tar.TypeReg
		}
		h := &tar.Header{Name: e.name, Typeflag: typ, Mode: 0o644, Linkname: e.link}
		if typ == tar.TypeReg {
			h.Size = int64(len(e.body))
		}
		if typ == tar.TypeDir {
			h.Mode = 0o755
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if typ == tar.TypeReg {
			if _, err := tw.Write([]byte(e.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// serverSkills is an archive as the server packs it: files only.
func serverSkills(t *testing.T) []byte {
	return tarGz(t,
		entry{name: "slipdock/SKILL.md", body: "the server's slipdock\n"},
		entry{name: "slipdock-loop/SKILL.md", body: "the server's loop\n"},
		entry{name: "slipdock-wiki/SKILL.md", body: "the server's wiki\n"},
		entry{name: "slipdock-wiki/references/api.md", body: "api\n"},
	)
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		return "<" + err.Error() + ">"
	}
	return string(data)
}

func skillsHome(r *rig) string { return filepath.Join(r.w.Home, ".claude", "skills") }

func TestAnAgentJobInstallsTheServersSkillsFirst(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	dir := skillsHome(r)
	writeFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md"), "a stale loop\n")
	writeFile(t, filepath.Join(dir, "slipdock-loop", "gone.md"), "a file the server no longer ships\n")
	writeFile(t, filepath.Join(dir, "other-skill", "SKILL.md"), "not ours\n")
	// A half-done earlier swap of a skill the archive ships: its leftover
	// must not end up in the installed copy.
	writeFile(t, filepath.Join(dir, "slipdock-loop.new", "stale.md"), "a half-done earlier swap\n")

	if f := r.runJob(fakeJob{id: 701, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
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
	if _, err := os.Stat(filepath.Join(dir, "slipdock-loop", "gone.md")); !os.IsNotExist(err) {
		t.Errorf("the skill is the server's whole: a file it no longer ships is gone (%v)", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "slipdock-loop", "stale.md")); !os.IsNotExist(err) {
		t.Errorf("a leftover of a half-done earlier swap was swapped in (%v)", err)
	}
	for _, n := range []string{"slipdock.new", "slipdock-loop.new", "slipdock-wiki.new"} {
		if _, err := os.Stat(filepath.Join(dir, n)); !os.IsNotExist(err) {
			t.Errorf("%s was left behind", n)
		}
	}
	if r.srv.skillsKey != "" {
		t.Errorf("the skills archive needs no key, and got one: %q", r.srv.skillsKey)
	}
	if !strings.Contains(r.logged.String(), "skills: installed the server's slipdock slipdock-loop slipdock-wiki (signed with the release key) in "+dir) {
		t.Errorf("the daemon's log says what it installed:\n%s", r.logged)
	}
	if !strings.Contains(r.srv.finishes[701].body, "skills: installed the server's") {
		t.Errorf("the job's log says so too: %q", r.srv.finishes[701].body)
	}
}

func TestTheSkillsGoInTheLocalFilesSkillsDir(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	r.w.Local.SkillsDir = filepath.Join(t.TempDir(), "elsewhere")

	if f := r.runJob(fakeJob{id: 702, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if got := readFile(t, filepath.Join(r.w.Local.SkillsDir, "slipdock", "SKILL.md")); got != "the server's slipdock\n" {
		t.Errorf("skills_dir's slipdock = %q", got)
	}
	if _, err := os.Stat(skillsHome(r)); !os.IsNotExist(err) {
		t.Errorf("nothing goes in ~/.claude/skills when skills_dir says elsewhere (%v)", err)
	}
}

func TestASymlinkedSkillIsLeftAlone(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	dir := skillsHome(r)
	checkout := filepath.Join(t.TempDir(), "priv", "skills", "slipdock-loop")
	writeFile(t, filepath.Join(checkout, "SKILL.md"), "my working copy\n")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(checkout, filepath.Join(dir, "slipdock-loop")); err != nil {
		t.Fatal(err)
	}

	if f := r.runJob(fakeJob{id: 703, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	fi, err := os.Lstat(filepath.Join(dir, "slipdock-loop"))
	if err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the symlink was replaced (%v, %v)", fi, err)
	}
	if got := readFile(t, filepath.Join(checkout, "SKILL.md")); got != "my working copy\n" {
		t.Errorf("the symlink's target was written: %q", got)
	}
	if got := readFile(t, filepath.Join(dir, "slipdock", "SKILL.md")); got != "the server's slipdock\n" {
		t.Errorf("the other skills are still installed: %q", got)
	}
	if !strings.Contains(r.logged.String(), filepath.Join(dir, "slipdock-loop")+" is a symlink; left alone") {
		t.Errorf("the log says it was left alone:\n%s", r.logged)
	}
	if strings.Contains(r.logged.String(), "installed the server's slipdock slipdock-loop") {
		t.Errorf("the symlinked skill isn't named as installed:\n%s", r.logged)
	}
}

func TestAFailedFetchKeepsTheInstalledSkillsAndTheJobRuns(t *testing.T) {
	cases := []struct {
		name string
		set  func(*server)
		says string
	}{
		{"not found", func(s *server) {}, "could not fetch the server's skills (HTTP 404)"},
		{"server error", func(s *server) { s.skillsCode = 500 }, "could not fetch the server's skills (HTTP 500)"},
		{"not gzip", func(s *server) { s.skills = []byte("<html>a proxy's page</html>") }, "could not unpack the server's skills"},
		{"cut short", func(s *server) { a := serverSkills(t); s.skills = a[:len(a)/2] }, "could not unpack the server's skills"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t, Config{})
			c.set(r.srv)
			installed := filepath.Join(skillsHome(r), "slipdock-loop", "SKILL.md")
			writeFile(t, installed, "the installed loop\n")

			f := r.runJob(fakeJob{id: 704, kind: "claude", card: 42, prompt: "x"})

			if f.exit != 0 || f.status != "" || !strings.Contains(f.body, "hello from the agent") {
				t.Fatalf("the job ran anyway: finish = %+v", f)
			}
			if got := readFile(t, installed); got != "the installed loop\n" {
				t.Errorf("the installed skill = %q, want it kept", got)
			}
			if !strings.Contains(r.logged.String(), c.says) || !strings.Contains(r.logged.String(), "keeping the ones in "+skillsHome(r)) {
				t.Errorf("the log says %q and that it kept them:\n%s", c.says, r.logged)
			}
			if !strings.Contains(f.body, "slipdock-runner: skills: ") {
				t.Errorf("the job's log says so: %q", f.body)
			}
		})
	}
}

func TestABadArchiveIsRefusedWholeAndNothingIsInstalled(t *testing.T) {
	good := entry{name: "slipdock/SKILL.md", body: "the server's slipdock\n"}
	cases := []struct {
		name string
		bad  []entry
		says string
	}{
		{"outside a slipdock folder", []entry{{name: "evil/SKILL.md", body: "x"}}, "evil/SKILL.md: not in a slipdock* folder"},
		{"at the top", []entry{{name: "SKILL.md", body: "x"}}, "SKILL.md: not in a slipdock* folder"},
		{"absolute", []entry{{name: "/etc/passwd", body: "x"}}, "/etc/passwd: not in a slipdock* folder"},
		{"dot dot", []entry{{name: "slipdock/../../.bashrc", body: "x"}}, "slipdock/../../.bashrc: a '..' in it"},
		{"dot dot at the end", []entry{{name: "slipdock-loop/..", typ: tar.TypeDir}}, "a '..' in it"},
		{"a dot", []entry{{name: "slipdock/./SKILL.md", body: "x"}}, "a '.' in it"},
		{"doubled slash", []entry{{name: "slipdock//SKILL.md", body: "x"}}, "not a clean path"},
		{"odd characters", []entry{{name: "slipdock/a b.md", body: "x"}}, "not in a slipdock* folder"},
		{"a symlink", []entry{{name: "slipdock-loop/SKILL.md", typ: tar.TypeSymlink, link: "/etc/passwd"}}, "not a file or folder"},
		{"a hard link", []entry{{name: "slipdock-loop/SKILL.md", typ: tar.TypeLink, link: "slipdock/SKILL.md"}}, "not a file or folder"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t, Config{})
			// The good entry first: one bad entry refuses the whole archive.
			r.srv.skills = tarGz(t, append([]entry{good}, c.bad...)...)
			installed := filepath.Join(skillsHome(r), "slipdock", "SKILL.md")
			writeFile(t, installed, "the installed slipdock\n")

			f := r.runJob(fakeJob{id: 705, kind: "claude", card: 42, prompt: "x"})

			if f.exit != 0 || !strings.Contains(f.body, "hello from the agent") {
				t.Fatalf("the job ran anyway: finish = %+v", f)
			}
			if got := readFile(t, installed); got != "the installed slipdock\n" {
				t.Errorf("the installed skill = %q, want it kept", got)
			}
			log := r.logged.String()
			if !strings.Contains(log, "the server's archive has an entry outside a slipdock skill") || !strings.Contains(log, c.says) {
				t.Errorf("the log says the archive was refused (%q):\n%s", c.says, log)
			}
			if strings.Contains(log, "installed the server's") {
				t.Errorf("nothing was installed:\n%s", log)
			}
		})
	}
}

func TestAFileEntryWithNoFileNameIsRefused(t *testing.T) {
	// Go's tar writer won't write a file whose name ends in a slash, but
	// another one can: write "slipdock-loopX" and make the X a slash.
	var raw bytes.Buffer
	tw := tar.NewWriter(&raw)
	if err := tw.WriteHeader(&tar.Header{Name: "slipdock-loopX", Typeflag: tar.TypeReg, Mode: 0o644}); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	b := raw.Bytes()
	b[len("slipdock-loop")] = '/'
	copy(b[148:156], "        ")
	sum := 0
	for _, c := range b[:512] {
		sum += int(c)
	}
	copy(b[148:156], fmt.Sprintf("%06o\x00 ", sum))
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	_, _ = zw.Write(b)
	_ = zw.Close()

	if _, err := readSkills(gz.Bytes()); err == nil || !strings.Contains(err.Error(), "slipdock-loop/: no file name") {
		t.Fatalf("readSkills(a file named slipdock-loop/) = %v", err)
	}
}

func TestAnEmptyArchiveIsRefused(t *testing.T) {
	if _, err := readSkills(tarGz(t)); err == nil || !strings.Contains(err.Error(), "(empty)") {
		t.Fatalf("readSkills(empty) = %v", err)
	}
}

func TestAnArchiveWithFolderEntriesAndADotSlashPrefixIsRead(t *testing.T) {
	skills, err := readSkills(tarGz(t,
		entry{name: "./slipdock-plan/", typ: tar.TypeDir},
		entry{name: "./slipdock-plan/SKILL.md", body: "plan"},
		entry{name: "slipdock-docs/", typ: tar.TypeDir},
		entry{name: "slipdock-docs/refs/", typ: tar.TypeDir},
		entry{name: "slipdock-docs/refs/a.md", body: "a"},
	))
	if err != nil {
		t.Fatal(err)
	}
	if len(skills) != 2 || len(skills["slipdock-plan"]) != 1 || skills["slipdock-docs"][0].rel != "refs/a.md" {
		t.Fatalf("readSkills = %+v", skills)
	}
}

func TestAnOversizedArchiveIsRefused(t *testing.T) {
	big := strings.Repeat("x", skillsMax/2+1)
	_, err := readSkills(tarGz(t, entry{name: "slipdock/a.md", body: big}, entry{name: "slipdock/b.md", body: big}))
	if err == nil || !strings.Contains(err.Error(), "over") {
		t.Fatalf("readSkills(too big) = %v", err)
	}
}

func TestLocalJSONTurnsTheSkillsUpdateOff(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	r.w.Local.NoSkillsUpdate = true
	installed := filepath.Join(skillsHome(r), "slipdock-loop", "SKILL.md")
	writeFile(t, installed, "the installed loop\n")

	if f := r.runJob(fakeJob{id: 706, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if got := readFile(t, installed); got != "the installed loop\n" {
		t.Errorf("the installed skill = %q, want it kept", got)
	}
	if r.srv.skillsGets != 0 {
		t.Errorf("no_skills_update fetched the archive %d times", r.srv.skillsGets)
	}
}

func TestAMergeAndAProbeDontInstallSkills(t *testing.T) {
	// Their git and gh are fake and have no origin, so a merge fails and
	// a probe goes red: neither matters, only that neither fetched the
	// skills.
	for _, kind := range []string{"merge", ProbeKind} {
		t.Run(kind, func(t *testing.T) {
			r := newRig(t, Config{})
			r.srv.skills = serverSkills(t)
			r.w.Exec = (&fakeGit{}).exec
			r.runJob(fakeJob{id: 707, kind: kind, card: 42, prompt: "probe\nskills: current\ncli: current\n",
				pr: "https://github.com/example/repo/pull/1", sha: strings.Repeat("a", 40)})
			if r.srv.skillsGets != 0 {
				t.Errorf("a %s job fetched the skills", kind)
			}
			if _, err := os.Stat(filepath.Join(skillsHome(r), "slipdock")); !os.IsNotExist(err) {
				t.Errorf("a %s job installed skills (%v)", kind, err)
			}
		})
	}
}

// asAccount is an executor that says it is the user executor, but can't
// run anything as the account (no Feed).
type asAccount struct{ *recorder }

func (asAccount) Name() string { return executor.User }

func TestUnderTheUserExecutorTheAccountsSkillsAreLeftAlone(t *testing.T) {
	r := newRig(t, Config{})
	r.srv.skills = serverSkills(t)
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	r.w.Executor = asAccount{&recorder{Executor: me, home: t.TempDir()}}

	if f := r.runJob(fakeJob{id: 708, kind: "claude", card: 42, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if r.srv.skillsGets != 0 {
		t.Errorf("the archive was fetched for skills it can't install")
	}
	if !strings.Contains(r.logged.String(), "skills: the jobs run as another account, which this executor can't write as") {
		t.Errorf("the log says why the skills were left:\n%s", r.logged)
	}
}

func TestASkillThatCantBePutInPlaceKeepsItsCopyAndTheRestGoIn(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("folder permissions differ on Windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	dir := t.TempDir()
	// slipdock-loop.new is a file in a folder the daemon can't write in,
	// so its staging fails; slipdock still goes in.
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
	put, notes := putSkills(dir, skills)
	if strings.Join(put, " ") != "slipdock slipdock-wiki" {
		t.Errorf("put = %v", put)
	}
	if len(notes) != 1 || !strings.Contains(notes[0], "could not put slipdock-loop in place") {
		t.Errorf("notes = %v", notes)
	}
	if got := readFile(t, filepath.Join(dir, "slipdock-loop", "SKILL.md")); got != "installed loop" {
		t.Errorf("the installed copy = %q, want it kept", got)
	}
}
