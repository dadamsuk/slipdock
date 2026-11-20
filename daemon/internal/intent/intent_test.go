package intent

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"
)

const origin = "https://slipdock.example.com"

// authenticator stands in for a passkey: it signs what a browser's
// navigator.credentials.get() would have it sign.
type authenticator struct {
	id   []byte
	priv crypto.Signer
	ed   bool
}

func newES256(t testing.TB) *authenticator {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &authenticator{id: []byte("cred-es256"), priv: k}
}

func newEd25519(t testing.TB) *authenticator {
	_, k, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &authenticator{id: []byte("cred-ed25519"), priv: k, ed: true}
}

func (a *authenticator) key(t testing.TB) Key {
	der, err := x509.MarshalPKIXPublicKey(a.priv.Public())
	if err != nil {
		t.Fatal(err)
	}
	return Key{CredentialID: a.id, SPKI: der}
}

// sign is the ceremony: the page asks for challenge, the browser writes
// clientDataJSON, the authenticator signs authData || SHA-256(clientData).
func (a *authenticator) sign(t testing.TB, challenge []byte, rpID, from string, flags byte) Assertion {
	cd, _ := json.Marshal(map[string]any{
		"type":        "webauthn.get",
		"challenge":   base64.RawURLEncoding.EncodeToString(challenge),
		"origin":      from,
		"crossOrigin": false,
	})
	rp := sha256.Sum256([]byte(rpID))
	ad := append(rp[:], flags, 0, 0, 0, 0)
	h := sha256.Sum256(cd)
	msg := append(append([]byte{}, ad...), h[:]...)
	var sig []byte
	var err error
	if a.ed {
		sig, err = a.priv.Sign(rand.Reader, msg, crypto.Hash(0))
	} else {
		d := sha256.Sum256(msg)
		sig, err = a.priv.Sign(rand.Reader, d[:], crypto.SHA256)
	}
	if err != nil {
		t.Fatal(err)
	}
	return Assertion{CredentialID: a.id, AuthenticatorData: ad, ClientDataJSON: cd, Signature: sig}
}

var signedAt = time.Date(2026, 11, 20, 5, 0, 0, 0, time.UTC)

func card() Fields {
	return Fields{
		Origin:      origin,
		CardID:      3523,
		SignedAt:    signedAt,
		Title:       "Add a CSV export",
		Description: "Export the board as CSV.\n\nOnly the visible columns.",
		Bar:         "1. `slipdock export --csv` writes one row per card; 2. tests",
	}
}

func pin(keys ...Key) Pin {
	return Pin{Origin: origin, RPID: "slipdock.example.com", Keys: keys, MaxAge: 30 * 24 * time.Hour}
}

func TestVerify(t *testing.T) {
	es, ed := newES256(t), newEd25519(t)
	p := pin(es.key(t), ed.key(t))
	now := signedAt.Add(time.Hour)
	const upuv = 0x05

	for _, a := range []*authenticator{es, ed} {
		if err := Verify(p, card(), a.sign(t, Challenge(card()), p.RPID, origin, upuv), 3523, now); err != nil {
			t.Errorf("%s: a good signature: %v", a.id, err)
		}
	}

	good := es.sign(t, Challenge(card()), p.RPID, origin, upuv)
	edited := func(f func(*Fields)) Fields { c := card(); f(&c); return c }

	cases := []struct {
		name string
		f    Fields
		a    Assertion
		job  int64
		now  time.Time
		p    Pin
		want error
	}{
		{"a word of the description changed", edited(func(c *Fields) { c.Description += " And the hidden ones." }), good, 3523, now, p, ErrChallenge},
		{"the bar changed", edited(func(c *Fields) { c.Bar = "1. anything" }), good, 3523, now, p, ErrChallenge},
		{"the title changed", edited(func(c *Fields) { c.Title = "Delete the board" }), good, 3523, now, p, ErrChallenge},
		{"text moved between fields", edited(func(c *Fields) { c.Title += "\ndescription 3\nfoo"; c.Description = c.Description[:0] }), good, 3523, now, p, ErrChallenge},
		{"replayed onto another card", edited(func(c *Fields) { c.CardID = 99 }), good, 99, now, p, ErrChallenge},
		{"the job is another card's", card(), good, 99, now, p, ErrCard},
		{"older than the ceiling allows", card(), good, 3523, signedAt.Add(31 * 24 * time.Hour), p, ErrStale},
		{"a key the machine doesn't pin", card(), func() *authenticator { o := newES256(t); o.id = []byte("cred-other"); return o }().sign(t, Challenge(card()), p.RPID, origin, upuv), 3523, now, p, ErrUnknownKey},
		{"signed for another site", card(), es.sign(t, Challenge(card()), "evil.example.com", origin, upuv), 3523, now, p, ErrOrigin},
		{"no user verification", card(), es.sign(t, Challenge(card()), p.RPID, origin, 0x01), 3523, now, p, ErrNotVerified},
		{"a sign-in challenge", card(), es.sign(t, make([]byte, 32), p.RPID, origin, upuv), 3523, now, p, ErrChallenge},
		{"signature tampered", card(), func() Assertion {
			a := good
			a.Signature = append([]byte{}, a.Signature...)
			a.Signature[len(a.Signature)-1] ^= 1
			return a
		}(), 3523, now, p, ErrSignature},
	}
	for _, c := range cases {
		if err := Verify(c.p, c.f, c.a, c.job, c.now); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

// TestFixture writes a sample ES256 assertion for checking with Wax, the
// server's WebAuthn library: INTENT_FIXTURE=/path go test -run Fixture.
func TestFixture(t *testing.T) {
	path := os.Getenv("INTENT_FIXTURE")
	if path == "" {
		t.Skip("INTENT_FIXTURE not set")
	}
	es := newES256(t)
	pub := es.priv.Public().(*ecdsa.PublicKey)
	a := es.sign(t, Challenge(card()), "slipdock.example.com", origin, 0x05)
	b64 := base64.RawURLEncoding.EncodeToString
	var x, y [32]byte
	pub.X.FillBytes(x[:])
	pub.Y.FillBytes(y[:])
	out, _ := json.Marshal(map[string]string{
		"challenge": b64(Challenge(card())), "credential_id": b64(a.CredentialID),
		"authenticator_data": b64(a.AuthenticatorData), "client_data_json": b64(a.ClientDataJSON),
		"signature": b64(a.Signature), "x": b64(x[:]), "y": b64(y[:]),
	})
	if err := os.WriteFile(path, out, 0o600); err != nil {
		t.Fatal(err)
	}
}

func BenchmarkVerifyES256(b *testing.B) {
	es := newES256(b)
	p := pin(es.key(b))
	a := es.sign(b, Challenge(card()), p.RPID, origin, 0x05)
	now := signedAt.Add(time.Hour)
	for b.Loop() {
		if err := Verify(p, card(), a, 3523, now); err != nil {
			b.Fatal(err)
		}
	}
}
