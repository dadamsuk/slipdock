package cli

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/intent"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// slipdock-runner trust-owner, init's offer of it, and doctor's check of
// the pinned keys (#3533).

type listedKey struct {
	Name         string `json:"name"`
	CredentialID string `json:"credential_id"`
	Algorithm    string `json:"algorithm"`
	SPKI         string `json:"spki"`
	Fingerprint  string `json:"fingerprint"`
}

func passkey(t *testing.T, name string, pub crypto.PublicKey) listedKey {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return listedKey{Name: name, CredentialID: base64.RawURLEncoding.EncodeToString([]byte("cred-" + name)),
		SPKI: base64.RawURLEncoding.EncodeToString(der), Fingerprint: intent.Fingerprint(der)}
}

func edKey(t *testing.T, name string) listedKey {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	k := passkey(t, name, pub)
	k.Algorithm = "EdDSA"
	return k
}

func esKey(t *testing.T, name string, curve elliptic.Curve) listedKey {
	priv, _ := ecdsa.GenerateKey(curve, rand.Reader)
	k := passkey(t, name, priv.Public())
	k.Algorithm = "ES256"
	return k
}

func ownerKeysJSON(owner int64, keys ...listedKey) string {
	if keys == nil {
		keys = []listedKey{}
	}
	out, _ := json.Marshal(map[string]any{"origin": "https://slipdock.example.com", "rp_id": "slipdock.example.com",
		"owner_id": owner, "keys": keys})
	return string(out)
}

const twoRunners = `{"version":3,"runners":[{"id":1,"name":"builder","board_id":3},{"id":2,"name":"verifier","board_id":3}]}`

func pinnedKeys(t *testing.T, w *world) []machine.OwnerKey {
	t.Helper()
	c, err := machine.LoadCeiling(w.dir)
	if err != nil {
		t.Fatal(err)
	}
	return c.OwnerKeys
}

func TestTrustOwnerShowsTheFingerprintsAndPinsWhatIsConfirmed(t *testing.T) {
	w, f := enrolled(t)
	laptop, phone, other := edKey(t, "laptop"), esKey(t, "phone", elliptic.P256()), edKey(t, "other")
	f.config = twoRunners
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, laptop, phone), "2": ownerKeysJSON(6, other)}

	// Declined: nothing written.
	w.env.Stdin = strings.NewReader("n\n")
	if code := w.main("trust-owner"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"Owner #5 (runners builder (#1)), signing on https://slipdock.example.com (rp id slipdock.example.com)",
		"- laptop  EdDSA  " + laptop.Fingerprint, "- phone  ES256  " + phone.Fingerprint,
		"Owner #6 (runners verifier (#2))", "- other  EdDSA  " + other.Fingerprint,
		"Pin 3 key(s)", "Nothing pinned."} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if got := pinnedKeys(t, w); len(got) != 0 {
		t.Fatalf("declined, but pinned %+v", got)
	}

	// Confirmed: each key with its owner, origin and rp id.
	w.env.Stdin = strings.NewReader("y\n")
	if code := w.main("trust-owner"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	got := pinnedKeys(t, w)
	if len(got) != 3 {
		t.Fatalf("pinned %+v", got)
	}
	want := machine.OwnerKey{OwnerID: 5, Name: "laptop", CredentialID: laptop.CredentialID, Algorithm: "EdDSA", SPKI: laptop.SPKI,
		Fingerprint: laptop.Fingerprint, Origin: "https://slipdock.example.com", RPID: "slipdock.example.com"}
	if got[0] != want || got[2].OwnerID != 6 {
		t.Fatalf("pinned %+v\nwant first %+v", got, want)
	}
	if !strings.Contains(w.out.String(), "Pinned 3 owner key(s)") || !strings.Contains(w.out.String(), "sets no tiers") {
		t.Fatalf("output:\n%s", w.out)
	}

	// Again, nothing has changed.
	w.env.Stdin = strings.NewReader("")
	if code := w.main("trust-owner"); code != 0 || !strings.Contains(w.out.String(), "nothing to change") {
		t.Fatalf("exit %d:\n%s", code, w.out)
	}

	// The owner lost the phone; owner 6's runner is gone: the phone is
	// unpinned, owner 6's key kept, as trust-owner didn't ask about them.
	f.config = `{"version":4,"runners":[{"id":1,"name":"builder","board_id":3}]}`
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, laptop)}
	if code := w.main("trust-owner", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(w.out.String(), "Unpins phone ("+phone.Fingerprint+")") {
		t.Fatalf("output:\n%s", w.out)
	}
	got = pinnedKeys(t, w)
	if len(got) != 2 || got[0].Name != "laptop" || got[1].Name != "other" {
		t.Fatalf("pinned %+v; want laptop and owner 6's key", got)
	}
}

func TestTrustOwnerLeavesOutAKeyItCantCheck(t *testing.T) {
	w, f := enrolled(t)
	good, p384, lying := edKey(t, "good"), esKey(t, "p384", elliptic.P384()), edKey(t, "lying")
	lying.Fingerprint = good.Fingerprint
	f.config = `{"version":3,"runners":[{"id":1,"name":"builder","board_id":3}]}`
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, good, p384, lying)}
	if code := w.main("trust-owner", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"- p384: left out, the daemon can't check its signatures (an ECDSA key not on P-256)",
		"- lying: left out, the server's fingerprint for it isn't its key's"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if got := pinnedKeys(t, w); len(got) != 1 || got[0].Name != "good" {
		t.Fatalf("pinned %+v", got)
	}
}

func TestTrustOwnerRefusals(t *testing.T) {
	w, f := enrolled(t)
	// No runners: nothing to ask the server with.
	f.config = `{"version":3,"runners":[]}`
	if code := w.main("trust-owner", "--yes"); code != 1 || !strings.Contains(w.errOut.String(), "no runners yet") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	// The server won't list a runner's owner's keys.
	f.config = twoRunners
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, edKey(t, "laptop"))}
	if code := w.main("trust-owner", "--yes"); code != 1 || !strings.Contains(w.errOut.String(), "runner verifier (#2)") {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if got := pinnedKeys(t, w); len(got) != 0 {
		t.Fatalf("a refusal pinned %+v", got)
	}
	// Not enrolled.
	if code := newWorld(t).main("trust-owner"); code != 1 {
		t.Fatalf("unenrolled: exit %d", code)
	}
}

func TestInitOffersToPinTheOwnersKeys(t *testing.T) {
	f := &fake{config: `{"version":3,"runners":[{"id":1,"name":"builder","board_id":3}]}`}
	laptop := edKey(t, "laptop")
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, laptop)}
	ts := f.start(t)
	w := newWorld(t)
	// No to setting up with Claude, yes to pinning, yes to the keys.
	w.env.Stdin = strings.NewReader("n\ny\ny\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--allow-http", "--key", "sdk_good", "--root", w.home); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if got := pinnedKeys(t, w); len(got) != 1 || got[0].Fingerprint != laptop.Fingerprint {
		t.Fatalf("pinned %+v\n%s", got, w.out)
	}

	// Skipped: init succeeds and pins nothing.
	w = newWorld(t)
	w.env.Stdin = strings.NewReader("n\nn\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--allow-http", "--key", "sdk_good", "--root", w.home); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if got := pinnedKeys(t, w); len(got) != 0 || !strings.Contains(w.out.String(), "Pin the board owners' passkeys now") {
		t.Fatalf("pinned %+v\n%s", got, w.out)
	}
	w = newWorld(t)
	w.env.Stdin = strings.NewReader("n\ny\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--allow-http", "--key", "sdk_good", "--root", w.home, "--no-trust-owner"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if strings.Contains(w.out.String(), "Pin the board owners' passkeys now") {
		t.Fatalf("--no-trust-owner asked:\n%s", w.out)
	}

	// No runners yet: init still succeeds, and says how to pin later.
	f.config = `{"version":3,"runners":[]}`
	w = newWorld(t)
	w.env.Stdin = strings.NewReader("n\ny\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--allow-http", "--key", "sdk_good", "--root", w.home); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(w.out.String(), "Not pinned: this machine has no runners yet") {
		t.Fatalf("output:\n%s", w.out)
	}
}

func TestDoctorWarnsOfAPinnedKeyTheOwnerNoLongerHas(t *testing.T) {
	w, f := enrolled(t)
	laptop, phone := edKey(t, "laptop"), edKey(t, "phone")
	f.config = `{"version":3,"runners":[{"id":1,"name":"builder","board_id":3}]}`
	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, laptop, phone)}
	if code := w.main("trust-owner", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}

	if code := w.main("doctor"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, w.out)
	}
	for _, want := range []string{"ok    owner keys: 2 pinned, each still one of the owners' passkeys",
		"warn  owner keys: pinned, but the ceiling sets no tiers"} {
		if !strings.Contains(w.out.String(), want) {
			t.Errorf("missing %q in\n%s", want, w.out)
		}
	}

	f.ownerKeys = map[string]string{"1": ownerKeysJSON(5, laptop)}
	if code := w.main("doctor"); code != 0 {
		t.Fatalf("a warning failed doctor: exit %d", code)
	}
	if want := "warn  owner key phone: " + phone.Fingerprint + " is pinned, but the owner's account no longer has it"; !strings.Contains(w.out.String(), want) {
		t.Errorf("missing %q in\n%s", want, w.out)
	}
	if strings.Contains(w.out.String(), "owner key laptop") {
		t.Errorf("warned of a key the owner still has:\n%s", w.out)
	}

	f.ownerKeys = nil
	if code := w.main("doctor"); code != 0 || !strings.Contains(w.out.String(), "warn  owner keys: can't check them") {
		t.Fatalf("exit %d:\n%s", code, w.out)
	}

	// Nothing pinned: no owner key lines at all.
	w2, _ := enrolled(t)
	if w2.main("doctor"); strings.Contains(w2.out.String(), "owner key") {
		t.Fatalf("no keys pinned, yet:\n%s", w2.out)
	}
}
