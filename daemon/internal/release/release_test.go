package release

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func newKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

const manifest = `{"version":"v1.2.0","files":{"linux/amd64":{"name":"slipdock-runner_v1.2.0_linux_amd64","sha256":"` +
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" + `","size":10}}}`

func TestSignAndVerify(t *testing.T) {
	pub, priv := newKey(t)
	sig := Sign(priv, []byte(manifest))
	if err := Verify(pub, []byte(manifest), sig); err != nil {
		t.Fatalf("own signature refused: %v", err)
	}
	m, err := VerifyManifest(pub, []byte(manifest), sig)
	if err != nil {
		t.Fatal(err)
	}
	f, ok := m.For("linux", "amd64")
	if m.Version != "v1.2.0" || !ok || f.Size != 10 {
		t.Fatalf("manifest read wrong: %+v", m)
	}
	if _, ok := m.For("windows", "arm64"); ok {
		t.Fatal("a platform the release lacks was found")
	}
}

func TestVerifyRefuses(t *testing.T) {
	pub, priv := newKey(t)
	other, otherPriv := newKey(t)
	sig := Sign(priv, []byte(manifest))

	cases := map[string]struct {
		key      ed25519.PublicKey
		msg, sig string
		want     string
	}{
		"a changed file":        {pub, strings.Replace(manifest, "v1.2.0", "v9.2.0", 1), string(sig), "does not match"},
		"another key's":         {pub, manifest, string(Sign(otherPriv, []byte(manifest))), "another key"},
		"checked with another":  {other, manifest, string(sig), "another key"},
		"not armored":           {pub, manifest, "hello", "not an armored"},
		"armored nonsense":      {pub, manifest, armorBegin + "\nAAAA\n" + armorEnd, "not an SSH signature"},
		"a flipped signature":   {pub, manifest, flip(sig), ""},
		"an empty signature":    {pub, manifest, "", "not an armored"},
		"the signature is junk": {pub, manifest, armorBegin + "\n!!!\n" + armorEnd, "not base64"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			err := Verify(c.key, []byte(c.msg), []byte(c.sig))
			if err == nil {
				t.Fatal("accepted")
			}
			if c.want != "" && !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %q, want it to say %q", err, c.want)
			}
		})
	}
}

// flip changes one byte of the signature's ed25519 bytes, near the end of
// the blob, and re-armors it.
func flip(armored []byte) string {
	blob, _ := dearmor(armored)
	blob[len(blob)-3] ^= 0xff
	return string(armor(blob))
}

func TestVerifyManifestRefusesMalformedSignedManifests(t *testing.T) {
	pub, priv := newKey(t)
	for name, data := range map[string]string{
		"not JSON":        `nope`,
		"a bad version":   `{"version":"1.2","files":{}}`,
		"a climbing name": strings.Replace(manifest, "slipdock-runner_v1.2.0_linux_amd64", "../evil", 1),
		"a short sha":     strings.Replace(manifest, "0123456789abcdef0123", "01", 1),
		"no size":         strings.Replace(manifest, `"size":10`, `"size":0`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := VerifyManifest(pub, []byte(data), Sign(priv, []byte(data))); err == nil {
				t.Fatal("accepted")
			}
		})
	}
	if _, err := VerifyManifest(nil, []byte(manifest), Sign(priv, []byte(manifest))); !errors.Is(err, ErrNoKey) {
		t.Fatalf("no key: got %v", err)
	}
}

func TestParsePublicKey(t *testing.T) {
	pub, _ := newKey(t)
	got, err := ParsePublicKey("# a comment\n\n" + AuthorizedKey(pub, "slipdock release") + "\n")
	if err != nil || !pub.Equal(got) {
		t.Fatalf("got %v, %v", got, err)
	}
	if _, err := ParsePublicKey("# nothing yet\n"); !errors.Is(err, ErrNoKey) {
		t.Fatalf("comments only: got %v", err)
	}
	if _, err := ParsePublicKey("ssh-rsa AAAAB3NzaC1yc2E= x"); err == nil {
		t.Fatal("an rsa key was taken")
	}
	if _, err := ParsePublicKey("ssh-ed25519 !!!"); err == nil {
		t.Fatal("junk was taken")
	}
}

// The embedded file is the repo's release_key.pub: a key or comments only,
// and never a private key.
func TestEmbeddedKeyIsAPublicKeyOrNone(t *testing.T) {
	if strings.Contains(embeddedKey, "PRIVATE KEY") {
		t.Fatal("release_key.pub holds a private key")
	}
	if _, err := Key(); err != nil && !errors.Is(err, ErrNoKey) {
		t.Fatalf("release_key.pub doesn't parse: %v", err)
	}
}

// What the release job and the install one-liner do (ssh-keygen -Y) and
// what the daemon does (Verify, Sign) agree, both ways.
func TestAgreesWithSSHKeygen(t *testing.T) {
	keygen, err := exec.LookPath("ssh-keygen")
	if err != nil {
		t.Skip("no ssh-keygen on this machine")
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "key")
	if out, err := exec.Command(keygen, "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", keyPath).CombinedOutput(); err != nil {
		t.Fatalf("keygen: %v %s", err, out)
	}
	pubText, _ := os.ReadFile(keyPath + ".pub")
	pub, err := ParsePublicKey(string(pubText))
	if err != nil {
		t.Fatal(err)
	}
	msgPath := filepath.Join(dir, ManifestFile)
	os.WriteFile(msgPath, []byte(manifest), 0o644)

	// ssh-keygen signs, Verify checks.
	if out, err := exec.Command(keygen, "-Y", "sign", "-f", keyPath, "-n", Namespace, msgPath).CombinedOutput(); err != nil {
		t.Fatalf("sign: %v %s", err, out)
	}
	sig, _ := os.ReadFile(msgPath + ".sig")
	if err := Verify(pub, []byte(manifest), sig); err != nil {
		t.Fatalf("ssh-keygen's signature refused: %v", err)
	}
	// In another namespace, the same key's signature is refused.
	os.Remove(msgPath + ".sig")
	exec.Command(keygen, "-Y", "sign", "-f", keyPath, "-n", "file", msgPath).Run()
	other, _ := os.ReadFile(msgPath + ".sig")
	if err := Verify(pub, []byte(manifest), other); err == nil || !strings.Contains(err.Error(), "not \"slipdock-runner\"") {
		t.Fatalf("another namespace: got %v", err)
	}

	// Sign signs, ssh-keygen checks (the installers' check).
	_, priv := newKey(t)
	signer := filepath.Join(dir, "allowed_signers")
	os.WriteFile(signer, []byte(`release namespaces="slipdock-runner" `+AuthorizedKey(priv.Public().(ed25519.PublicKey), "")+"\n"), 0o644)
	ours := filepath.Join(dir, "ours.sig")
	os.WriteFile(ours, Sign(priv, []byte(manifest)), 0o644)
	cmd := exec.Command(keygen, "-Y", "verify", "-f", signer, "-I", "release", "-n", Namespace, "-s", ours)
	cmd.Stdin = strings.NewReader(manifest)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen refused Sign's signature: %v %s", err, out)
	}
}

func TestNewer(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"v1.2.0", "v1.1.9", true},
		{"v1.10.0", "v1.9.0", true},
		{"v1.2.0", "v1.2.0", false},
		{"v1.1.0", "v1.2.0", false},
		{"v2.0.0", "v1.99.99", true},
		{"v1.2.0", "v1.2.0-rc.1", true},
		{"v1.2.0-rc.1", "v1.2.0", false},
		{"v1.2.0-rc.2", "v1.2.0-rc.1", true},
		{"v1.2.0-rc.10", "v1.2.0-rc.9", true},
		{"v1.2.0-rc.1", "v1.2.0-beta", true},
		{"v1.2.0-rc", "v1.2.0-rc.1", false},
		{"v0.1.0", "dev", true},
	} {
		got, err := Newer(c.a, c.b)
		if err != nil || got != c.want {
			t.Errorf("Newer(%s, %s) = %v, %v; want %v", c.a, c.b, got, err, c.want)
		}
	}
	if _, err := Newer("dev", "v1.0.0"); err == nil {
		t.Error("a dev build was a release")
	}
	if IsRelease("dev") || !IsRelease("v1.0.0") {
		t.Error("IsRelease")
	}
}

// The CLI's signature (#2669) is the same key in a namespace of its own:
// a release manifest's signature is no CLI's, and a CLI's no release's.
func TestTheCLIsNamespaceIsItsOwn(t *testing.T) {
	pub, priv := newKey(t)
	escript := []byte("#!/usr/bin/env escript\nthe CLI\n")
	cliSig := SignIn(CLINamespace, priv, escript)
	if err := VerifyIn(CLINamespace, pub, escript, cliSig); err != nil {
		t.Fatalf("the CLI's own signature refused: %v", err)
	}
	if err := Verify(pub, escript, cliSig); err == nil || !strings.Contains(err.Error(), `not "slipdock-runner"`) {
		t.Errorf("a CLI signature passed as a release's: %v", err)
	}
	if err := VerifyIn(CLINamespace, pub, escript, Sign(priv, escript)); err == nil || !strings.Contains(err.Error(), `not "slipdock-cli"`) {
		t.Errorf("a release signature passed as the CLI's: %v", err)
	}
	if err := VerifyIn(CLINamespace, nil, escript, cliSig); !errors.Is(err, ErrNoKey) {
		t.Errorf("no key: got %v", err)
	}
	if CLINamespace == Namespace {
		t.Fatal("the CLI shares the release's namespace")
	}
}

// What the release job does for the CLI (ssh-keygen -Y sign -n
// slipdock-cli) is what VerifyIn takes.
func TestTheCLIsSignatureAgreesWithSSHKeygen(t *testing.T) {
	keygen, err := exec.LookPath("ssh-keygen")
	if err != nil {
		t.Skip("no ssh-keygen on this machine")
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "key")
	if out, err := exec.Command(keygen, "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", keyPath).CombinedOutput(); err != nil {
		t.Fatalf("keygen: %v %s", err, out)
	}
	pubText, _ := os.ReadFile(keyPath + ".pub")
	pub, err := ParsePublicKey(string(pubText))
	if err != nil {
		t.Fatal(err)
	}
	escript := filepath.Join(dir, "slipdock.escript")
	body := []byte("#!/usr/bin/env escript\nthe CLI\n")
	os.WriteFile(escript, body, 0o644)
	if out, err := exec.Command(keygen, "-Y", "sign", "-f", keyPath, "-n", CLINamespace, escript).CombinedOutput(); err != nil {
		t.Fatalf("sign: %v %s", err, out)
	}
	sig, _ := os.ReadFile(escript + ".sig")
	if err := VerifyIn(CLINamespace, pub, body, sig); err != nil {
		t.Fatalf("ssh-keygen's CLI signature refused: %v", err)
	}
}
