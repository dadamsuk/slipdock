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

// ps1Run says how runInstallPs1 runs install.ps1: against a plain http
// release host, as the one-liner's scriptblock form with -AllowHttp, or
// with noAllowHTTP as `… | iex`, which can pass no switch; source, if
// set, in place of the release host.
type ps1Run struct {
	tamper      bool
	noAllowHTTP bool
	source      string
}

func runInstallPs1(t *testing.T, r ps1Run) (string, string, error) {
	t.Helper()
	tamper := r.tamper
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
	run := "& ([scriptblock]::Create((Get-Content -Raw '" + script + "'))) -AllowHttp"
	if r.noAllowHTTP {
		run = "Get-Content -Raw '" + script + "' | iex"
	}
	source := ts.URL + "/rel"
	if r.source != "" {
		source = r.source
	}
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", run)
	cmd.Env = append(os.Environ(), "SLIPDOCK_RUNNER_SOURCE="+source, "SLIPDOCK_RUNNER_BIN="+dest)
	out, err := cmd.CombinedOutput()
	return string(out), filepath.Join(dest, "slipdock-runner.exe"), err
}

func TestInstallPs1InstallsASignedRelease(t *testing.T) {
	out, exe, err := runInstallPs1(t, ps1Run{})
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !strings.Contains(out, "downloading over plain http from") || !strings.Contains(out, "(-AllowHttp)") {
		t.Fatalf("-AllowHttp installs, and warns:\n%s", out)
	}
	if got, err := os.ReadFile(exe); err != nil || string(got) != "MZ a slipdock-runner\r\n" {
		t.Fatalf("installed %q, %v\n%s", got, err, out)
	}
}

func TestInstallPs1RefusesATamperedBinary(t *testing.T) {
	out, exe, err := runInstallPs1(t, ps1Run{tamper: true})
	if err == nil || !strings.Contains(out, "REFUSED") {
		t.Fatalf("%v\n%s", err, out)
	}
	if _, err := os.Stat(exe); err == nil {
		t.Fatal("something was installed")
	}
}

func TestInstallPs1RefusesPlainHTTPUnlessAllowed(t *testing.T) {
	out, exe, err := runInstallPs1(t, ps1Run{noAllowHTTP: true})
	if err == nil || !strings.Contains(out, "is plain http: use https, or pass -AllowHttp") {
		t.Fatalf("%v\n%s", err, out)
	}
	if _, err := os.Stat(exe); err == nil {
		t.Fatal("something was installed")
	}
}

func TestInstallPs1RefusesAnotherScheme(t *testing.T) {
	out, exe, err := runInstallPs1(t, ps1Run{source: "ftp://releases.example.com"})
	if err == nil || !strings.Contains(out, "is not an https:// address") {
		t.Fatalf("%v\n%s", err, out)
	}
	if strings.Contains(out, "downloading over plain http") {
		t.Fatalf("an ftp source isn't taken for http:\n%s", out)
	}
	if _, err := os.Stat(exe); err == nil {
		t.Fatal("something was installed")
	}
}
