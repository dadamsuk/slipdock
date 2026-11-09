package machine

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestDirHonoursTheOverride(t *testing.T) {
	d := t.TempDir()
	got, err := Dir(env(map[string]string{HomeEnv: d}))
	if err != nil || got != d {
		t.Fatalf("Dir = %q, %v; want %q", got, err, d)
	}
}

func TestDirDefaultsUnderTheConfigDirectory(t *testing.T) {
	got, err := Dir(env(nil))
	if err != nil {
		t.Skip("no config directory on this machine:", err)
	}
	if !strings.HasSuffix(got, filepath.Join("slipdock-runner", "machine")) {
		t.Fatalf("Dir = %q: want it in slipdock-runner/machine, apart from the shell runner's files", got)
	}
}

func TestSaveAndLoad(t *testing.T) {
	d := filepath.Join(t.TempDir(), "m")
	if Enrolled(d) {
		t.Fatal("an empty directory is not enrolled")
	}
	st := State{Server: "https://slipdock.example.com", MachineID: 7, Name: "box", Boards: []int64{3}, EnrolledVia: "device"}
	if err := Save(d, st, "sdm_secret"); err != nil {
		t.Fatal(err)
	}
	if !Enrolled(d) {
		t.Fatal("saved, so enrolled")
	}
	got, key, err := Load(d)
	if err != nil {
		t.Fatal(err)
	}
	if key != "sdm_secret" || got.MachineID != 7 || got.Server != st.Server || got.Boards[0] != 3 {
		t.Fatalf("Load = %+v, %q", got, key)
	}
	if runtime.GOOS != "windows" {
		assertMode(t, filepath.Join(d, KeyFile), 0o600)
		assertMode(t, d, 0o700)
	}
}

func TestSaveTightensAnExistingDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix modes")
	}
	d := t.TempDir()
	if err := os.Chmod(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Save(d, State{}, "k"); err != nil {
		t.Fatal(err)
	}
	assertMode(t, d, 0o700)
}

func TestSaveRefusesAnEmptyKey(t *testing.T) {
	d := t.TempDir()
	if err := Save(d, State{}, ""); err == nil {
		t.Fatal("an empty key must not be saved")
	}
	if Enrolled(d) {
		t.Fatal("nothing should have been written")
	}
}

func TestLoadErrors(t *testing.T) {
	d := t.TempDir()
	if _, _, err := Load(d); !errors.Is(err, ErrNotEnrolled) {
		t.Fatalf("no key: %v, want ErrNotEnrolled", err)
	}

	write(t, filepath.Join(d, KeyFile), "sdm_x\n")
	if _, _, err := Load(d); err == nil || !strings.Contains(err.Error(), "init --replace") {
		t.Fatalf("no state: %v", err)
	}

	write(t, filepath.Join(d, StateFile), "{not json")
	if _, _, err := Load(d); err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Fatalf("bad state: %v", err)
	}

	write(t, filepath.Join(d, StateFile), "{}")
	write(t, filepath.Join(d, KeyFile), "\n")
	if _, _, err := Load(d); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("empty key: %v", err)
	}
}

func TestIdentityIsMadeOnceAndKept(t *testing.T) {
	d := t.TempDir()
	a, err := LoadOrCreateIdentity(d)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadOrCreateIdentity(d)
	if err != nil {
		t.Fatal(err)
	}
	if a.Fingerprint() != b.Fingerprint() {
		t.Fatal("the fingerprint must survive a second load")
	}
	fp := a.Fingerprint()
	if len(fp) != 39 || strings.Count(fp, ":") != 7 {
		t.Fatalf("fingerprint %q: want eight groups of four hex digits", fp)
	}
	if runtime.GOOS != "windows" {
		assertMode(t, filepath.Join(d, IdentityFile), 0o600)
	}
	other, _ := LoadOrCreateIdentity(t.TempDir())
	if other.Fingerprint() == fp {
		t.Fatal("two machines got one fingerprint")
	}
}

func TestADamagedIdentityIsRefused(t *testing.T) {
	d := t.TempDir()
	write(t, filepath.Join(d, IdentityFile), "zz")
	if _, err := LoadOrCreateIdentity(d); err == nil || !strings.Contains(err.Error(), "damaged") {
		t.Fatalf("got %v", err)
	}
}

func TestProposeCeiling(t *testing.T) {
	home := t.TempDir()
	c := ProposeCeiling(home, []int64{9, 3})
	if c.Roots[0] != filepath.Join(home, "src") {
		t.Fatalf("with no source folder, propose ~/src: %v", c.Roots)
	}
	if c.Agents[0] != "claude" || c.MaxPermissionMode != "acceptEdits" || c.MaxTimeoutMinutes != 60 {
		t.Fatalf("defaults: %+v", c)
	}
	if c.Boards[0] != 3 || c.Boards[1] != 9 {
		t.Fatalf("boards sorted: %v", c.Boards)
	}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}

	if err := os.Mkdir(filepath.Join(home, "dev"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := ProposeCeiling(home, []int64{1}).Roots[0]; got != filepath.Join(home, "dev") {
		t.Fatalf("an existing ~/dev is the source folder: %s", got)
	}
}

func TestValidateSaysWhatIsWrong(t *testing.T) {
	good := ProposeCeiling(t.TempDir(), []int64{1})
	cases := map[string]func(*Ceiling){
		"roots: name at least one":   func(c *Ceiling) { c.Roots = nil },
		"is not an absolute path":    func(c *Ceiling) { c.Roots = []string{"relative/dir"} },
		"agents: name at least one":  func(c *Ceiling) { c.Agents = nil },
		"is not a name":              func(c *Ceiling) { c.Agents = []string{"rm -rf /"} },
		"max_permission_mode":        func(c *Ceiling) { c.MaxPermissionMode = "yolo" },
		"max_timeout_minutes":        func(c *Ceiling) { c.MaxTimeoutMinutes = 0 },
		"boards: the machine serves": func(c *Ceiling) { c.Boards = nil },
	}
	for want, breakIt := range cases {
		c := good
		breakIt(&c)
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v", want, err)
		}
	}
	long := good
	long.MaxTimeoutMinutes = 24*60 + 1
	if long.Validate() == nil {
		t.Error("a timeout over a day is refused")
	}
}

func TestModeRank(t *testing.T) {
	if !(ModeRank("plan") < ModeRank("default") && ModeRank("default") < ModeRank("acceptEdits") &&
		ModeRank("acceptEdits") < ModeRank("bypassPermissions")) {
		t.Fatal("modes rank from least to most permissive")
	}
	if ModeRank("other") != -1 {
		t.Fatal("an unknown mode ranks -1")
	}
}

func TestCeilingRoundTripAndStrictness(t *testing.T) {
	d := t.TempDir()
	c := ProposeCeiling(t.TempDir(), []int64{3})
	if err := SaveCeiling(d, c); err != nil {
		t.Fatal(err)
	}
	got, err := LoadCeiling(d)
	if err != nil || got.MaxPermissionMode != c.MaxPermissionMode || got.Roots[0] != c.Roots[0] {
		t.Fatalf("LoadCeiling = %+v, %v", got, err)
	}

	bad := c
	bad.MaxPermissionMode = "yolo"
	if err := SaveCeiling(d, bad); err == nil {
		t.Fatal("an invalid ceiling is not saved")
	}

	// A field the daemon doesn't know (a typo, or a command smuggled in) is refused.
	write(t, filepath.Join(d, CeilingFile), `{"roots":["/x"],"agents":["claude"],"max_permission_mode":"plan","max_timeout_minutes":5,"boards":[1],"command":"sh"}`)
	if _, err := LoadCeiling(d); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("got %v", err)
	}
	write(t, filepath.Join(d, CeilingFile), `{"roots":[],"agents":["claude"],"max_permission_mode":"plan","max_timeout_minutes":5,"boards":[1]}`)
	if _, err := LoadCeiling(d); err == nil {
		t.Fatal("an invalid ceiling on disk is refused")
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := fi.Mode().Perm(); got != want {
		t.Fatalf("%s is mode %o, want %o", path, got, want)
	}
}

func write(t *testing.T, path, s string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTheCeilingsExecutors(t *testing.T) {
	d := t.TempDir()
	c := ProposeCeiling(t.TempDir(), []int64{3})
	if len(c.Executors) != 1 || c.Executors[0] != "me" {
		t.Fatalf("proposed: %v", c.Executors)
	}
	c.Executors = []string{"user", "root"}
	if err := SaveCeiling(d, c); err == nil || !strings.Contains(err.Error(), `executors: "root"`) {
		t.Fatalf("%v", err)
	}
	// A ceiling written before there were executors reads as me only.
	c.Executors = nil
	if err := SaveCeiling(d, c); err != nil {
		t.Fatal(err)
	}
	if got, err := LoadCeiling(d); err != nil || len(got.Executors) != 1 || got.Executors[0] != "me" {
		t.Fatalf("%+v %v", got, err)
	}
	c.Executors = []string{"user", "confined"}
	_ = SaveCeiling(d, c)
	if got, _ := LoadCeiling(d); strings.Join(got.Executors, ",") != "user,confined" {
		t.Fatal(got.Executors)
	}
}

func TestTheCeilingsContainerImages(t *testing.T) {
	d := t.TempDir()
	c := ProposeCeiling(t.TempDir(), []int64{3})
	if len(c.ContainerImages) != 0 {
		t.Fatalf("init proposes no images: %v", c.ContainerImages)
	}
	for _, bad := range []string{"*", "*/agent", "ghcr.io/me agent", ""} {
		c.ContainerImages = []string{"ghcr.io/me/*", bad}
		if err := SaveCeiling(d, c); err == nil || !strings.Contains(err.Error(), "container_images: ") {
			t.Errorf("saved a ceiling allowing %q: %v", bad, err)
		}
	}
	c.Executors = []string{"me", "container"}
	c.ContainerImages = []string{"ghcr.io/me/agent:*", "slipdock-agent:*"}
	if err := SaveCeiling(d, c); err != nil {
		t.Fatal(err)
	}
	got, err := LoadCeiling(d)
	if err != nil || strings.Join(got.ContainerImages, ",") != "ghcr.io/me/agent:*,slipdock-agent:*" {
		t.Fatalf("%+v %v", got, err)
	}
}
