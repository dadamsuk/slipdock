package daemon

// install.ps1, run as its one-liner (`… | iex`) in Windows PowerShell, on
// the daemon's Windows CI job: it installs a signed release and refuses a
// tampered one, leaving nothing installed.

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

func runInstallPs1(t *testing.T, tamper bool) (string, string, error) {
	t.Helper()
	if runtime.GOOS != "windows" {
		t.Skip("install.ps1 is for Windows")
	}
	if _, err := exec.LookPath("ssh-keygen.exe"); err != nil {
		t.Skip("no ssh-keygen here")
	}
	arch := map[string]string{"amd64": "amd64", "arm64": "arm64"}[runtime.GOARCH]
	if arch == "" {
		t.Skip("no build for " + runtime.GOARCH)
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	bin := []byte("MZ a slipdock-runner\r\n")
	name := release.BinaryName("v1.5.0", "windows/"+arch)
	sum := sha256.Sum256(bin)
	m, _ := release.MarshalManifest(release.Manifest{Version: "v1.5.0", Files: map[string]release.File{
		"windows/" + arch: {Name: name, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(bin))},
	}})
	files := map[string][]byte{release.ManifestFile: m, release.SignatureFile: release.Sign(priv, m), name: bin}
	if tamper {
		files[name] = []byte("MZ an evil binary!\r\n")
	}
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		data, ok := files[strings.TrimPrefix(r.URL.Path, "/rel/")]
		if !ok {
			rw.WriteHeader(404)
			return
		}
		rw.Write(data)
	}))
	defer ts.Close()

	src, err := os.ReadFile("install.ps1")
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(t.TempDir(), "install.ps1")
	os.WriteFile(script, []byte(strings.Replace(string(src), "__SLIPDOCK_RELEASE_KEY__", release.AuthorizedKey(pub, ""), 1)), 0o644)
	dest := filepath.Join(t.TempDir(), "bin")
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
		"Get-Content -Raw '"+script+"' | iex")
	cmd.Env = append(os.Environ(), "SLIPDOCK_RUNNER_SOURCE="+ts.URL+"/rel", "SLIPDOCK_RUNNER_BIN="+dest)
	out, err := cmd.CombinedOutput()
	return string(out), filepath.Join(dest, "slipdock-runner.exe"), err
}

func TestInstallPs1InstallsASignedRelease(t *testing.T) {
	out, exe, err := runInstallPs1(t, false)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if got, err := os.ReadFile(exe); err != nil || string(got) != "MZ a slipdock-runner\r\n" {
		t.Fatalf("installed %q, %v\n%s", got, err, out)
	}
}

func TestInstallPs1RefusesATamperedBinary(t *testing.T) {
	out, exe, err := runInstallPs1(t, true)
	if err == nil || !strings.Contains(out, "REFUSED") {
		t.Fatalf("%v\n%s", err, out)
	}
	if _, err := os.Stat(exe); err == nil {
		t.Fatal("something was installed")
	}
}
