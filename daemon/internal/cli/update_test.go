package cli

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
	"github.com/dadamsuk/slipdock/daemon/internal/update"
)

// releases is a host serving signed releases, and counting what it's asked.
type releases struct {
	mu    sync.Mutex
	files map[string][]byte
	asked int
	priv  ed25519.PrivateKey
	url   string
}

const newBin = "slipdock-runner_v1.3.0_linux_amd64"

// withReleases signs with a key of the test's own, serves v1.3.0, and
// makes this binary v1.2.0 at w's executable path.
func withReleases(t *testing.T, w *world) *releases {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	r := &releases{files: map[string][]byte{}, priv: priv}
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		defer r.mu.Unlock()
		r.asked++
		data, ok := r.files[strings.TrimPrefix(req.URL.Path, "/rel/")]
		if !ok {
			rw.WriteHeader(404)
			return
		}
		rw.Write(data)
	}))
	t.Cleanup(ts.Close)
	r.url = ts.URL + "/rel"
	r.publish("v1.3.0", []byte("new binary\n"))

	oldKey, oldVersion, oldNow := releaseKey, Version, now
	releaseKey = func() (ed25519.PublicKey, error) { return pub, nil }
	Version = "v1.2.0"
	now = func() time.Time { return time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC) }
	t.Cleanup(func() { releaseKey, Version, now = oldKey, oldVersion, oldNow })

	exe, _ := w.env.Executable()
	os.MkdirAll(filepath.Dir(exe), 0o755)
	os.WriteFile(exe, []byte("old binary\n"), 0o755)
	if code := w.main("update", "--source", r.url); code != 0 {
		t.Fatalf("setting the source: %s", w.errOut)
	}
	return r
}

func (r *releases) publish(version string, bin []byte) {
	sum := sha256.Sum256(bin)
	m, _ := json.Marshal(release.Manifest{Version: version, Files: map[string]release.File{
		"linux/amd64": {Name: newBin, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(bin))},
	}})
	r.files[release.ManifestFile] = m
	r.files[release.SignatureFile] = release.Sign(r.priv, m)
	r.files[newBin] = bin
}

func (r *releases) tamper() { r.files[newBin] = []byte("evil binary") }

func exeHolds(t *testing.T, w *world, want string) {
	t.Helper()
	exe, _ := w.env.Executable()
	got, _ := os.ReadFile(exe)
	if string(got) != want {
		t.Fatalf("the binary holds %q, want %q", got, want)
	}
}

func lastCheck(t *testing.T, w *world) *update.Check {
	t.Helper()
	s, err := update.Load(w.dir)
	if err != nil || s.Last == nil {
		t.Fatalf("no check recorded: %+v %v", s, err)
	}
	return s.Last
}

func TestUpdateCheckThenInstall(t *testing.T) {
	w := newWorld(t)
	withReleases(t, w)

	if code := w.main("update", "--check"); code != 0 || !strings.Contains(w.out.String(), "v1.3.0 is available (this is v1.2.0)") {
		t.Fatalf("check: %d %s %s", code, w.out, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
	if c := lastCheck(t, w); c.Outcome != update.Available {
		t.Fatalf("%+v", c)
	}

	if code := w.main("update"); code != 0 || !strings.Contains(w.out.String(), "Updated v1.2.0 to v1.3.0") {
		t.Fatalf("update: %d %s %s", code, w.out, w.errOut)
	}
	exeHolds(t, w, "new binary\n")
	if c := lastCheck(t, w); c.Outcome != update.Installed {
		t.Fatalf("%+v", c)
	}
}

func TestUpdateUpToDate(t *testing.T) {
	w := newWorld(t)
	r := withReleases(t, w)
	r.publish("v1.2.0", []byte("same\n"))
	if code := w.main("update"); code != 0 || !strings.Contains(w.out.String(), "Up to date: v1.2.0") {
		t.Fatalf("%d %s %s", code, w.out, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
}

// A tampered binary is refused and reported: by the command, in
// update.json, by show and by doctor.
func TestATamperedUpdateIsRefusedAndReported(t *testing.T) {
	w, _ := enrolled(t)
	r := withReleases(t, w)
	r.tamper()

	if code := w.main("update"); code != 1 || !strings.Contains(w.errOut.String(), "refused") ||
		!strings.Contains(w.errOut.String(), "this binary is as it was") {
		t.Fatalf("%d %s", code, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
	if c := lastCheck(t, w); c.Outcome != update.Refused || !strings.Contains(c.Reason, "SHA-256") {
		t.Fatalf("%+v", c)
	}

	if code := w.main("show"); code != 0 || !strings.Contains(w.out.String(), "Last check:    refused at 2026-11-09T12:00:00Z") {
		t.Fatalf("show: %d %s", code, w.out)
	}
	if code := w.main("doctor"); code != 1 || !strings.Contains(w.out.String(), "FAIL  updates: the update checked 2026-11-09T12:00:00Z was refused") {
		t.Fatalf("doctor: %d %s", code, w.out)
	}
}

func TestUpdateRefusesWithoutAKey(t *testing.T) {
	w := newWorld(t)
	withReleases(t, w)
	releaseKey = func() (ed25519.PublicKey, error) { return nil, release.ErrNoKey }
	if code := w.main("update"); code != 1 || !strings.Contains(w.errOut.String(), "no release key") {
		t.Fatalf("%d %s", code, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
}

func TestUpdateSettings(t *testing.T) {
	w := newWorld(t)
	if code := w.main("update", "--mode", "manual"); code != 0 || !strings.Contains(w.out.String(), "Updates: manual, from "+update.DefaultSource) {
		t.Fatalf("%d %s %s", code, w.out, w.errOut)
	}
	if code := w.main("update", "--source", "https://mirror.example.com/r"); code != 0 || !strings.Contains(w.out.String(), "manual, from https://mirror.example.com/r") {
		t.Fatalf("%d %s", code, w.out)
	}
	if code := w.main("update", "--source", "default", "--mode", "auto"); code != 0 || !strings.Contains(w.out.String(), "auto, from "+update.DefaultSource) {
		t.Fatalf("%d %s", code, w.out)
	}
	if code := w.main("update", "--mode", "sometimes"); code != 1 || !strings.Contains(w.errOut.String(), "auto or manual") {
		t.Fatalf("%d %s", code, w.errOut)
	}
	if code := w.main("update", "now"); code != 2 {
		t.Fatalf("a stray argument: %d", code)
	}
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	b, _ := os.ReadFile(path)
	return string(b)
}

func TestRunInstallsAnUpdateAndRestarts(t *testing.T) {
	w, _ := enrolled(t)
	withReleases(t, w)
	logFile := filepath.Join(t.TempDir(), "daemon.log")
	w.stopAfterSleep = 5
	if code := w.main("run", "--log", logFile); code != 1 || !strings.Contains(w.errOut.String(), "updated") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	exeHolds(t, w, "new binary\n")
	if log := readLog(t, logFile); !strings.Contains(log, "updated v1.2.0 to v1.3.0, signature and checksum checked; restarting") {
		t.Fatalf("log:\n%s", log)
	}
}

// An update found when run starts restarts the daemon before its runners
// start, so no runner has taken a job the restart would stop.
func TestRunUpdatesAtStartBeforeAnyRunnerClaims(t *testing.T) {
	w, f := enrolled(t)
	withReleases(t, w)
	f.config = `{"version":1,"runners":[
		{"id":21,"name":"builder","board_id":3,"pool":"default","config_version":1,
		 "config":{"agent":"claude","directory":` + jsonString(filepath.Join(w.home, "repo")) + `,"permission_mode":"acceptEdits","timeout_minutes":30,"executor":"me","worktree":"auto"}}]}`
	f.claimStatus = 204
	if code := w.main("run"); code != 1 || !strings.Contains(w.errOut.String(), "updated") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	exeHolds(t, w, "new binary\n")
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.claims) != 0 {
		t.Fatalf("runners claimed before the restart: %v", f.claims)
	}
}

func TestRunInManualModeOnlyReports(t *testing.T) {
	w, _ := enrolled(t)
	withReleases(t, w)
	w.main("update", "--mode", "manual")
	logFile := filepath.Join(t.TempDir(), "daemon.log")
	w.stopAfterSleep = 2
	if code := w.main("run", "--log", logFile); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
	if log := readLog(t, logFile); !strings.Contains(log, "v1.3.0 is available (this is v1.2.0); updates are manual") {
		t.Fatalf("log:\n%s", log)
	}
}

func TestRunRefusesATamperedUpdateAndCarriesOn(t *testing.T) {
	w, _ := enrolled(t)
	r := withReleases(t, w)
	r.tamper()
	logFile := filepath.Join(t.TempDir(), "daemon.log")
	w.stopAfterSleep = 2
	if code := w.main("run", "--log", logFile); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	exeHolds(t, w, "old binary\n")
	log := readLog(t, logFile)
	if !strings.Contains(log, "REFUSED an update from "+r.url) || !strings.Contains(log, "nothing was installed") {
		t.Fatalf("log:\n%s", log)
	}
	if c := lastCheck(t, w); c.Outcome != update.Refused {
		t.Fatalf("%+v", c)
	}
}

func TestRunChecksForUpdatesOnlyEverySoOften(t *testing.T) {
	w, _ := enrolled(t)
	r := withReleases(t, w)
	w.main("update", "--mode", "manual")
	old := updateEvery
	updateEvery = 3
	t.Cleanup(func() { updateEvery = old })
	r.asked = 0
	w.stopAfterSleep = 7 // seven checks of the enrolment: updates at the start, 3 and 6
	w.main("run")
	if r.asked != 3*2 { // the manifest and its signature, each time
		t.Fatalf("asked %d times", r.asked)
	}
}

func TestADevBuildDoesntUpdateItself(t *testing.T) {
	w, _ := enrolled(t)
	r := withReleases(t, w)
	Version = "dev"
	r.asked = 0
	w.stopAfterSleep = 2
	if code := w.main("run"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if r.asked != 0 {
		t.Fatalf("a dev build fetched %d times", r.asked)
	}
	exeHolds(t, w, "old binary\n")
	if code := w.main("doctor"); !strings.Contains(w.out.String(), "warn  updates: a dev build doesn't update itself") {
		t.Fatalf("doctor: %d %s", code, w.out)
	}
}
