package update

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

// host serves a release: any host, since the signature is what's checked.
type host struct {
	files map[string][]byte
}

func (h *host) start(t *testing.T) *httptest.Server {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/r/")
		if h.files["boom"] != nil {
			w.WriteHeader(500)
			return
		}
		data, ok := h.files[name]
		if !ok {
			w.WriteHeader(404)
			return
		}
		w.Write(data)
	}))
	t.Cleanup(ts.Close)
	return ts
}

type world struct {
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
	host *host
	u    Updater
	exe  string
}

const binName = "slipdock-runner_v1.3.0_linux_amd64"

var newBinary = []byte("#!new slipdock-runner v1.3.0\n")

func manifestFor(version string, bin []byte) []byte {
	sum := sha256.Sum256(bin)
	m := release.Manifest{Version: version, Files: map[string]release.File{
		"linux/amd64": {Name: binName, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(bin))},
	}}
	data, _ := json.Marshal(m)
	return data
}

func setup(t *testing.T) *world {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	w := &world{pub: pub, priv: priv, host: &host{files: map[string][]byte{}}}
	w.publish("v1.3.0", newBinary)
	ts := w.host.start(t)
	w.exe = filepath.Join(t.TempDir(), "slipdock-runner")
	os.WriteFile(w.exe, []byte("old"), 0o755)
	w.u = Updater{HTTP: ts.Client(), Source: ts.URL + "/r", Key: pub, Current: "v1.2.0", GOOS: "linux", GOARCH: "amd64", Exe: w.exe}
	return w
}

func (w *world) publish(version string, bin []byte) {
	m := manifestFor(version, bin)
	w.host.files[release.ManifestFile] = m
	w.host.files[release.SignatureFile] = release.Sign(w.priv, m)
	w.host.files[binName] = bin
}

func (w *world) exeIs(t *testing.T, want string) {
	t.Helper()
	got, _ := os.ReadFile(w.exe)
	if string(got) != want {
		t.Fatalf("the binary is %q, want %q", got, want)
	}
}

var now = time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)

func TestInstallsANewerSignedRelease(t *testing.T) {
	w := setup(t)
	c, err := w.u.Run(context.Background(), true, now)
	if err != nil || c.Outcome != Installed || c.Latest != "v1.3.0" || c.Current != "v1.2.0" {
		t.Fatalf("got %+v, %v", c, err)
	}
	w.exeIs(t, string(newBinary))
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(w.exe); st.Mode().Perm() != 0o755 {
			t.Fatalf("mode %v", st.Mode())
		}
	}
	// Nothing left beside it.
	entries, _ := os.ReadDir(filepath.Dir(w.exe))
	if len(entries) != 1 {
		t.Fatalf("left behind: %v", entries)
	}
}

func TestCheckOnlyReportsWithoutInstalling(t *testing.T) {
	w := setup(t)
	c, err := w.u.Run(context.Background(), false, now)
	if err != nil || c.Outcome != Available || c.Latest != "v1.3.0" {
		t.Fatalf("got %+v, %v", c, err)
	}
	w.exeIs(t, "old")
}

func TestNothingNewerOrOlderIsNotInstalled(t *testing.T) {
	for _, v := range []string{"v1.2.0", "v1.1.0"} {
		t.Run(v, func(t *testing.T) {
			w := setup(t)
			w.publish(v, newBinary)
			c, err := w.u.Run(context.Background(), true, now)
			if err != nil || c.Outcome != Current {
				t.Fatalf("got %+v, %v", c, err)
			}
			w.exeIs(t, "old")
		})
	}
}

func TestRefusesWhatDoesntVerify(t *testing.T) {
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	cases := map[string]func(w *world){
		"a tampered binary": func(w *world) {
			w.host.files[binName] = []byte("#!bad slipdock-runner v1.3.0\n") // the same size
		},
		"a binary of another size": func(w *world) { w.host.files[binName] = []byte("short") },
		"a manifest changed after signing": func(w *world) {
			w.host.files[release.ManifestFile] = manifestFor("v1.3.0", []byte("evil"))
		},
		"a manifest signed with another key": func(w *world) {
			w.host.files[release.SignatureFile] = release.Sign(otherPriv, w.host.files[release.ManifestFile])
		},
		"no signature":        func(w *world) { delete(w.host.files, release.SignatureFile) },
		"a junk signature":    func(w *world) { w.host.files[release.SignatureFile] = []byte("trust me") },
		"a build with no key": func(w *world) { w.u.Key = nil },
	}
	reasons := map[string]string{
		"a tampered binary":                  "SHA-256",
		"a binary of another size":           "but the signed manifest says",
		"a manifest changed after signing":   "does not match",
		"a manifest signed with another key": "another key",
		"no signature":                       "has no signature",
		"a build with no key":                "no release key",
	}
	for name, spoil := range cases {
		t.Run(name, func(t *testing.T) {
			w := setup(t)
			spoil(w)
			c, err := w.u.Run(context.Background(), true, now)
			if !IsRefused(err) || c.Outcome != Refused || c.Reason == "" {
				t.Fatalf("got %+v, %v", c, err)
			}
			if want := reasons[name]; want != "" && !strings.Contains(c.Reason, want) {
				t.Fatalf("reason %q, want it to say %q", c.Reason, want)
			}
			w.exeIs(t, "old")
		})
	}
}

func TestFailuresToFetchAreNotRefusals(t *testing.T) {
	w := setup(t)
	w.host.files["boom"] = []byte("x")
	c, err := w.u.Run(context.Background(), true, now)
	if err == nil || IsRefused(err) || c.Outcome != Failed {
		t.Fatalf("got %+v, %v", c, err)
	}

	w = setup(t)
	w.u.GOARCH = "riscv64"
	c, err = w.u.Run(context.Background(), true, now)
	if err == nil || c.Outcome != Failed || !strings.Contains(c.Reason, "no build for linux/riscv64") {
		t.Fatalf("got %+v, %v", c, err)
	}
	w.exeIs(t, "old")
}

func TestSettings(t *testing.T) {
	dir := t.TempDir()
	s, err := Load(dir)
	if err != nil || s.ModeOrDefault() != Auto || s.SourceOrDefault() != DefaultSource {
		t.Fatalf("defaults: %+v %v", s, err)
	}
	s.Mode, s.Source = Manual, "https://mirror.example.com/releases/"
	s.Last = &Check{At: now, Outcome: Refused, Reason: "bad"}
	if err := Save(dir, s); err != nil {
		t.Fatal(err)
	}
	got, err := Load(dir)
	if err != nil || got.ModeOrDefault() != Manual || got.SourceOrDefault() != "https://mirror.example.com/releases" || got.Last.Outcome != Refused {
		t.Fatalf("got %+v %v", got, err)
	}
	os.WriteFile(filepath.Join(dir, File), []byte(`{"mode":"sometimes"}`), 0o644)
	if _, err := Load(dir); err == nil {
		t.Fatal("a bad mode was taken")
	}
	os.WriteFile(filepath.Join(dir, File), []byte(`{`), 0o644)
	if _, err := Load(dir); err == nil {
		t.Fatal("bad JSON was taken")
	}
}
