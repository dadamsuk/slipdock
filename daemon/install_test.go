package daemon

// The install one-liner (install.sh) against a release host: it installs
// a signed release and refuses anything that doesn't verify, leaving
// nothing installed.

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

type installWorld struct {
	// mu guards files: the release host's handler reads it on the server's
	// goroutines, and the race detector can't see that the write before
	// the run happened first (it is ordered only through curl, another
	// process), so every read and write takes the lock (#2644).
	mu     sync.Mutex
	files  map[string][]byte
	priv   ed25519.PrivateKey
	script string
	url    string
	bin    string
	name   string
	hits   int // requests the release host has had, under mu
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
		w.mu.Lock()
		w.hits++
		data, ok := w.files[strings.TrimPrefix(r.URL.Path, "/rel/")]
		w.mu.Unlock()
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
	w.mu.Lock()
	defer w.mu.Unlock()
	w.files[release.ManifestFile] = m
	w.files[release.SignatureFile] = release.Sign(w.priv, m)
	w.files[w.name] = bin
}

// spoil changes what the release host serves, under the lock.
func (w *installWorld) spoil(f func(files map[string][]byte)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	f(w.files)
}

// served is what the release host serves at name.
func (w *installWorld) served(name string) []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.files[name]
}

// run runs script with --allow-http, as the test release host is plain
// http; runWith gives the arguments and the source.
func (w *installWorld) run(t *testing.T, script string) (string, error) {
	t.Helper()
	return w.runWith(t, script, w.url, "--allow-http")
}

func (w *installWorld) runWith(t *testing.T, script, source string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "SLIPDOCK_RUNNER_SOURCE="+source, "SLIPDOCK_RUNNER_BIN="+w.bin, "HOME="+t.TempDir())
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
	if err != nil || string(got) != string(w.served(w.name)) {
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
		spoil func(name string, files map[string][]byte)
		want  string
	}{
		"a tampered binary": {func(name string, files map[string][]byte) { files[name] = []byte("#!/bin/sh\necho evil\n") }, "SHA-256"},
		"a manifest changed after signing": {func(_ string, files map[string][]byte) {
			files[release.ManifestFile] = []byte(strings.Replace(string(files[release.ManifestFile]), "v1.5.0", "v9.9.9", 1))
		}, "not signed with the project's release key"},
		"another key's signature": {func(_ string, files map[string][]byte) {
			files[release.SignatureFile] = release.Sign(otherPriv, files[release.ManifestFile])
		}, "not signed with the project's release key"},
		"no signature": {func(_ string, files map[string][]byte) { delete(files, release.SignatureFile) }, "can't download release.json.sig"},
	} {
		t.Run(name, func(t *testing.T) {
			w := newInstallWorld(t)
			w.spoil(func(files map[string][]byte) { c.spoil(w.name, files) })
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

func TestInstallShRefusesPlainHTTPUnlessAllowed(t *testing.T) {
	for name, c := range map[string]struct {
		source func(w *installWorld) string
		args   []string
		want   string
	}{
		"plain http, no flag":   {func(w *installWorld) string { return w.url }, nil, "is plain http: use https, or pass --allow-http"},
		"HTTP in capitals":      {func(w *installWorld) string { return "HTTP" + strings.TrimPrefix(w.url, "http") }, nil, "is not an https:// address"},
		"another scheme":        {func(w *installWorld) string { return "ftp://releases.example.com" }, []string{"--allow-http"}, "is not an https:// address"},
		"an option it lacks":    {func(w *installWorld) string { return w.url }, []string{"--allow-htp"}, "unknown option --allow-htp"},
		"a source with no form": {func(w *installWorld) string { return "releases.example.com" }, nil, "is not an https:// address"},
	} {
		t.Run(name, func(t *testing.T) {
			w := newInstallWorld(t)
			out, err := w.runWith(t, w.script, c.source(w), c.args...)
			if err == nil || !strings.Contains(out, c.want) {
				t.Fatalf("%v\n%s", err, out)
			}
			w.mu.Lock()
			hits := w.hits
			w.mu.Unlock()
			if hits != 0 {
				t.Fatalf("refused, but fetched %d times first", hits)
			}
			if _, err := w.installed(); err == nil {
				t.Fatal("something was installed")
			}
		})
	}

	w := newInstallWorld(t)
	out, err := w.runWith(t, w.script, w.url, "--allow-http")
	if err != nil || !strings.Contains(out, "warning: downloading over plain http") {
		t.Fatalf("--allow-http installs, and warns: %v\n%s", err, out)
	}
	if got, err := w.installed(); err != nil || string(got) != string(w.served(w.name)) {
		t.Fatalf("installed %q, %v", got, err)
	}
}

// tlsHost serves the release over https, through handler, and returns its
// URL and the environment curl needs to trust it. It skips when this
// curl can't take a CA from CURL_CA_BUNDLE (macOS's, built on
// SecureTransport, reads only the keychain).
func (w *installWorld) tlsHost(t *testing.T, handler http.HandlerFunc) (string, []string) {
	t.Helper()
	ts := httptest.NewTLSServer(handler)
	t.Cleanup(ts.Close)
	ca := filepath.Join(t.TempDir(), "ca.pem")
	os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ts.Certificate().Raw}), 0o644)
	env := []string{"CURL_CA_BUNDLE=" + ca}
	probe := exec.Command("curl", "-fsS", "-o", os.DevNull, ts.URL+"/probe")
	probe.Env = append(os.Environ(), env...)
	if out, err := probe.CombinedOutput(); err != nil && strings.Contains(string(out), "certificate") {
		t.Skip("this curl doesn't take a CA from CURL_CA_BUNDLE: " + string(out))
	}
	return ts.URL + "/rel", env
}

func (w *installWorld) runEnv(t *testing.T, source string, env []string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", append([]string{w.script}, args...)...)
	cmd.Env = append(append(os.Environ(), env...), "SLIPDOCK_RUNNER_SOURCE="+source, "SLIPDOCK_RUNNER_BIN="+w.bin, "HOME="+t.TempDir())
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// An https source installs with no flag and no warning; one whose host
// redirects to plain http is refused, the http host never reached, even
// with --allow-http (which is for an http source, not a downgrade).
func TestInstallShKeepsHTTPSRedirectsOnHTTPS(t *testing.T) {
	w := newInstallWorld(t)
	src, env := w.tlsHost(t, func(rw http.ResponseWriter, r *http.Request) {
		data := w.served(strings.TrimPrefix(r.URL.Path, "/rel/"))
		if data == nil {
			rw.WriteHeader(404)
			return
		}
		rw.Write(data)
	})
	out, err := w.runEnv(t, src, env)
	if err != nil || strings.Contains(out, "warning") {
		t.Fatalf("an https source installs, quietly: %v\n%s", err, out)
	}
	if got, err := w.installed(); err != nil || string(got) != string(w.served(w.name)) {
		t.Fatalf("installed %q, %v", got, err)
	}

	for _, args := range [][]string{nil, {"--allow-http"}} {
		t.Run(strings.Join(append([]string{"redirect"}, args...), " "), func(t *testing.T) {
			w := newInstallWorld(t)
			src, env := w.tlsHost(t, func(rw http.ResponseWriter, r *http.Request) {
				http.Redirect(rw, r, w.url+strings.TrimPrefix(r.URL.Path, "/rel"), http.StatusFound)
			})
			out, err := w.runEnv(t, src, env, args...)
			if err == nil || !strings.Contains(out, "can't download release.json from "+src) {
				t.Fatalf("%v\n%s", err, out)
			}
			w.mu.Lock()
			hits := w.hits
			w.mu.Unlock()
			if hits != 0 {
				t.Fatalf("followed the redirect to plain http: %d requests there", hits)
			}
			if _, err := w.installed(); err == nil {
				t.Fatal("something was installed")
			}
		})
	}
}
