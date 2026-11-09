package daemon

// The install one-liner (install.sh) against a release host: it installs
// a signed release and refuses anything that doesn't verify, leaving
// nothing installed.

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

type installWorld struct {
	files  map[string][]byte
	priv   ed25519.PrivateKey
	script string
	url    string
	bin    string
	name   string
}

func newInstallWorld(t *testing.T) *installWorld {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("install.sh is for Linux and macOS")
	}
	for _, tool := range []string{"sh", "ssh-keygen", "curl"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("no " + tool + " here")
		}
	}
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		t.Skip("no build for " + runtime.GOARCH)
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	w := &installWorld{files: map[string][]byte{}, priv: priv, bin: filepath.Join(t.TempDir(), "bin")}
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		data, ok := w.files[strings.TrimPrefix(r.URL.Path, "/rel/")]
		if !ok {
			rw.WriteHeader(404)
			return
		}
		rw.Write(data)
	}))
	t.Cleanup(ts.Close)
	w.url = ts.URL + "/rel"

	src, err := os.ReadFile("install.sh")
	if err != nil {
		t.Fatal(err)
	}
	w.script = filepath.Join(t.TempDir(), "install.sh")
	keyed := strings.Replace(string(src), "__SLIPDOCK_RELEASE_KEY__", release.AuthorizedKey(pub, ""), 1)
	os.WriteFile(w.script, []byte(keyed), 0o755)

	w.name = release.BinaryName("v1.5.0", runtime.GOOS+"/"+runtime.GOARCH)
	w.publish([]byte("#!/bin/sh\necho slipdock-runner v1.5.0\n"))
	return w
}

func (w *installWorld) publish(bin []byte) {
	sum := sha256.Sum256(bin)
	m, _ := release.MarshalManifest(release.Manifest{Version: "v1.5.0", Files: map[string]release.File{
		runtime.GOOS + "/" + runtime.GOARCH: {Name: w.name, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(bin))},
	}})
	w.files[release.ManifestFile] = m
	w.files[release.SignatureFile] = release.Sign(w.priv, m)
	w.files[w.name] = bin
}

func (w *installWorld) run(t *testing.T, script string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", script)
	cmd.Env = append(os.Environ(), "SLIPDOCK_RUNNER_SOURCE="+w.url, "SLIPDOCK_RUNNER_BIN="+w.bin, "HOME="+t.TempDir())
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (w *installWorld) installed() ([]byte, error) {
	return os.ReadFile(filepath.Join(w.bin, "slipdock-runner"))
}

func TestInstallShInstallsASignedRelease(t *testing.T) {
	w := newInstallWorld(t)
	out, err := w.run(t, w.script)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	got, err := w.installed()
	if err != nil || string(got) != string(w.files[w.name]) {
		t.Fatalf("installed %q, %v", got, err)
	}
	if st, _ := os.Stat(filepath.Join(w.bin, "slipdock-runner")); st.Mode().Perm() != 0o755 {
		t.Fatalf("mode %v", st.Mode())
	}
	if !strings.Contains(out, "installed slipdock-runner v1.5.0") || !strings.Contains(out, "is not on your PATH") {
		t.Fatalf("said:\n%s", out)
	}
}

func TestInstallShRefusesWhatDoesntVerify(t *testing.T) {
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	for name, c := range map[string]struct {
		spoil func(w *installWorld)
		want  string
	}{
		"a tampered binary": {func(w *installWorld) { w.files[w.name] = []byte("#!/bin/sh\necho evil\n") }, "SHA-256"},
		"a manifest changed after signing": {func(w *installWorld) {
			w.files[release.ManifestFile] = []byte(strings.Replace(string(w.files[release.ManifestFile]), "v1.5.0", "v9.9.9", 1))
		}, "not signed with the project's release key"},
		"another key's signature": {func(w *installWorld) {
			w.files[release.SignatureFile] = release.Sign(otherPriv, w.files[release.ManifestFile])
		}, "not signed with the project's release key"},
		"no signature": {func(w *installWorld) { delete(w.files, release.SignatureFile) }, "can't download release.json.sig"},
	} {
		t.Run(name, func(t *testing.T) {
			w := newInstallWorld(t)
			c.spoil(w)
			out, err := w.run(t, w.script)
			if err == nil || !strings.Contains(out, c.want) {
				t.Fatalf("%v\n%s", err, out)
			}
			if _, err := w.installed(); err == nil {
				t.Fatal("something was installed")
			}
		})
	}
}

func TestInstallShWithNoKeyRefuses(t *testing.T) {
	w := newInstallWorld(t)
	out, err := w.run(t, "install.sh") // the repo's copy: the key not yet written in
	if err == nil || !strings.Contains(out, "has no release key") {
		t.Fatalf("%v\n%s", err, out)
	}
	if _, err := w.installed(); err == nil {
		t.Fatal("something was installed")
	}
}
