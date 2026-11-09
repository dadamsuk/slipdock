package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

func TestWritesAManifestForEveryPlatform(t *testing.T) {
	dir := t.TempDir()
	for _, p := range release.Platforms {
		os.WriteFile(filepath.Join(dir, release.BinaryName("v1.4.0", p)), []byte("bin "+p), 0o755)
	}
	if err := run("v1.4.0", dir); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, release.ManifestFile))
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	m, err := release.VerifyManifest(pub, data, release.Sign(priv, data))
	if err != nil {
		t.Fatal(err)
	}
	f, ok := m.For("windows", "arm64")
	if !ok || f.Name != "slipdock-runner_v1.4.0_windows_arm64.exe" || f.Size != int64(len("bin windows/arm64")) {
		t.Fatalf("%+v", m)
	}
	// One platform to a line, which is how install.sh reads it.
	lines := 0
	for _, l := range strings.Split(string(data), "\n") {
		if strings.Contains(l, `"sha256"`) {
			lines++
		}
	}
	if lines != len(release.Platforms) {
		t.Fatalf("%d entry lines:\n%s", lines, data)
	}
}

func TestRefusesAMissingBuildOrABadVersion(t *testing.T) {
	dir := t.TempDir()
	if err := run("v1.4.0", dir); err == nil || !strings.Contains(err.Error(), "build") {
		t.Fatalf("got %v", err)
	}
	for _, p := range release.Platforms {
		os.WriteFile(filepath.Join(dir, release.BinaryName("1.4", p)), []byte("x"), 0o755)
	}
	if err := run("1.4", dir); err == nil {
		t.Fatal("a bad version was taken")
	}
}
