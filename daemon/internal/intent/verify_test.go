package intent

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

const origin = "https://slipdock.example.com"
const rpID = "slipdock.example.com"

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

func newRS256(t testing.TB) *authenticator {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return &authenticator{id: []byte("cred-rs256"), priv: k}
}

func spki(t testing.TB, pub crypto.PublicKey) []byte {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

func (a *authenticator) key(t testing.TB) Key {
	return Key{CredentialID: a.id, SPKI: spki(t, a.priv.Public()), Origin: origin, RPID: rpID}
}

type ceremony struct {
	challenge   []byte
	rpID, from  string
	typ         string
	flags       byte
	crossOrigin bool
}

func good(f Fields) ceremony {
	return ceremony{challenge: Challenge(f), rpID: rpID, from: origin, typ: "webauthn.get", flags: 0x05}
}

// sign is the ceremony: the page asks for challenge, the browser writes
// clientDataJSON, the authenticator signs authData || SHA-256(clientData).
func (a *authenticator) sign(t testing.TB, c ceremony) Assertion {
	cd, _ := json.Marshal(map[string]any{
		"type":        c.typ,
		"challenge":   base64.RawURLEncoding.EncodeToString(c.challenge),
		"origin":      c.from,
		"crossOrigin": c.crossOrigin,
	})
	rp := sha256.Sum256([]byte(c.rpID))
	ad := append(rp[:], c.flags, 0, 0, 0, 0)
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
	return Pin{Keys: keys, MaxAge: 30 * 24 * time.Hour}
}

func TestVerifyAcceptsEachAlgorithm(t *testing.T) {
	es, ed, rs := newES256(t), newEd25519(t), newRS256(t)
	p := pin(es.key(t), ed.key(t), rs.key(t))
	now := signedAt.Add(time.Hour)
	for _, a := range []*authenticator{es, ed, rs} {
		if err := Verify(p, card(), a.sign(t, good(card())), 3523, now); err != nil {
			t.Errorf("%s: a good signature: %v", a.id, err)
		}
	}
}

func TestVerifyRefuses(t *testing.T) {
	es := newES256(t)
	p := pin(es.key(t))
	now := signedAt.Add(time.Hour)
	ok := es.sign(t, good(card()))
	edited := func(f func(*Fields)) Fields { c := card(); f(&c); return c }
	with := func(f func(*ceremony)) Assertion { c := good(card()); f(&c); return es.sign(t, c) }
	other := newES256(t)
	other.id = []byte("cred-other")
	// A key the machine pins under the same credential id, but not the one
	// that signed.
	swapped := pin(Key{CredentialID: es.id, SPKI: spki(t, other.priv.Public()), Origin: origin, RPID: rpID})
	otherServer := pin(Key{CredentialID: es.id, SPKI: es.key(t).SPKI, Origin: "https://other.example.com", RPID: rpID})

	cases := []struct {
		name string
		f    Fields
		a    Assertion
		job  int64
		now  time.Time
		p    Pin
		want error
	}{
		{"a word of the description changed", edited(func(c *Fields) { c.Description += " And the hidden ones." }), ok, 3523, now, p, ErrChallenge},
		{"the bar changed", edited(func(c *Fields) { c.Bar = "1. anything" }), ok, 3523, now, p, ErrChallenge},
		{"the title changed", edited(func(c *Fields) { c.Title = "Delete the board" }), ok, 3523, now, p, ErrChallenge},
		{"text moved between fields", edited(func(c *Fields) { c.Title += "\ndescription 3\nfoo"; c.Description = "" }), ok, 3523, now, p, ErrChallenge},
		{"signed-at moved", edited(func(c *Fields) { c.SignedAt = signedAt.Add(time.Hour) }), ok, 3523, now.Add(time.Hour), p, ErrChallenge},
		{"replayed onto another card", edited(func(c *Fields) { c.CardID = 99 }), ok, 99, now, p, ErrChallenge},
		{"the job is another card's", card(), ok, 99, now, p, ErrCard},
		{"the job has no card", edited(func(c *Fields) { c.CardID = 0 }), ok, 0, now, p, ErrCard},
		{"older than the ceiling allows", card(), ok, 3523, signedAt.Add(31 * 24 * time.Hour), p, ErrStale},
		{"signed in the future", card(), ok, 3523, signedAt.Add(-time.Hour), p, ErrStale},
		{"no max age set", card(), ok, 3523, now, Pin{Keys: p.Keys}, ErrStale},
		{"a key the machine doesn't pin", card(), other.sign(t, good(card())), 3523, now, p, ErrUnknownKey},
		{"no keys pinned", card(), ok, 3523, now, Pin{MaxAge: p.MaxAge}, ErrUnknownKey},
		{"no credential id", card(), func() Assertion { a := ok; a.CredentialID = nil; return a }(), 3523, now, p, ErrUnknownKey},
		{"the text names another server", edited(func(c *Fields) { c.Origin = "https://other.example.com" }), ok, 3523, now, p, ErrOrigin},
		{"the key is pinned for another server", card(), ok, 3523, now, otherServer, ErrOrigin},
		{"the browser was on another origin", card(), with(func(c *ceremony) { c.from = "https://evil.example.com" }), 3523, now, p, ErrOrigin},
		{"a cross-origin frame", card(), with(func(c *ceremony) { c.crossOrigin = true }), 3523, now, p, ErrOrigin},
		{"signed for another relying party", card(), with(func(c *ceremony) { c.rpID = "evil.example.com" }), 3523, now, p, ErrRPID},
		{"a registration, not an assertion", card(), with(func(c *ceremony) { c.typ = "webauthn.create" }), 3523, now, p, ErrType},
		{"no user verification", card(), with(func(c *ceremony) { c.flags = 0x01 }), 3523, now, p, ErrNotVerified},
		{"no user presence", card(), with(func(c *ceremony) { c.flags = 0x04 }), 3523, now, p, ErrNotVerified},
		{"a sign-in challenge", card(), with(func(c *ceremony) { c.challenge = make([]byte, 32) }), 3523, now, p, ErrChallenge},
		{"clientDataJSON isn't JSON", card(), func() Assertion { a := ok; a.ClientDataJSON = []byte("{"); return a }(), 3523, now, p, ErrMalformed},
		{"authenticatorData too short", card(), func() Assertion { a := ok; a.AuthenticatorData = a.AuthenticatorData[:36]; return a }(), 3523, now, p, ErrMalformed},
		{"signature tampered", card(), func() Assertion {
			a := ok
			a.Signature = append([]byte{}, a.Signature...)
			a.Signature[len(a.Signature)-1] ^= 1
			return a
		}(), 3523, now, p, ErrSignature},
		{"another key under the pinned credential id", card(), ok, 3523, now, swapped, ErrSignature},
	}
	for _, c := range cases {
		if err := Verify(c.p, c.f, c.a, c.job, c.now); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

func TestParseKey(t *testing.T) {
	for _, c := range []struct {
		a   *authenticator
		alg string
	}{{newES256(t), "ES256"}, {newEd25519(t), "EdDSA"}, {newRS256(t), "RS256"}} {
		if _, alg, err := ParseKey(spki(t, c.a.priv.Public())); err != nil || alg != c.alg {
			t.Errorf("%s: %q %v", c.alg, alg, err)
		}
	}
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	small, _ := rsa.GenerateKey(rand.Reader, 1024)
	for name, der := range map[string][]byte{
		"P-384":    spki(t, p384.Public()),
		"RSA 1024": spki(t, small.Public()),
		"garbage":  []byte("not a key"),
	} {
		if _, _, err := ParseKey(der); err == nil {
			t.Errorf("%s: taken", name)
		}
	}
	der := spki(t, newES256(t).priv.Public())
	if fp := Fingerprint(der); !strings.HasPrefix(fp, "sha256:") || len(fp) != 7+64 {
		t.Errorf("fingerprint %q", fp)
	}
}

// signedJSON is the server's answer for an assertion over f.
func signedJSON(f Fields, a Assertion) Signed {
	b := base64.RawURLEncoding.EncodeToString
	s := Signed{Signed: true, Version: Version, Origin: f.Origin, CardID: f.CardID,
		SignedAt: f.SignedAt.UTC().Format(time.RFC3339), Title: f.Title, Description: f.Description, Bar: f.Bar}
	s.Assertion.CredentialID = b(a.CredentialID)
	s.Assertion.AuthenticatorData = b(a.AuthenticatorData)
	s.Assertion.ClientDataJSON = b(a.ClientDataJSON)
	s.Assertion.Signature = b(a.Signature)
	return s
}

func TestPartsReadTheServersAnswer(t *testing.T) {
	es := newES256(t)
	a := es.sign(t, good(card()))
	s := signedJSON(card(), a)
	// Through JSON, as it comes, the padded base64url the server may send too.
	s.Assertion.Signature = base64.URLEncoding.EncodeToString(a.Signature)
	raw, _ := json.Marshal(s)
	var back Signed
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	f, got, err := back.Parts()
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(pin(es.key(t)), f, got, 3523, signedAt.Add(time.Hour)); err != nil {
		t.Fatalf("the parts don't verify: %v", err)
	}

	for name, c := range map[string]struct {
		s    Signed
		want error
		says string
	}{
		"unsigned":         {Signed{State: "unsigned"}, ErrUnsigned, "(unsigned)"},
		"edited":           {Signed{State: "edited"}, ErrUnsigned, "(edited)"},
		"no state":         {Signed{}, ErrUnsigned, "(unsigned)"},
		"another version":  {func() Signed { x := s; x.Version = "slipdock-intent-v2"; return x }(), ErrVersion, ""},
		"no version":       {func() Signed { x := s; x.Version = ""; return x }(), ErrVersion, ""},
		"a bad signed-at":  {func() Signed { x := s; x.SignedAt = "yesterday"; return x }(), ErrMalformed, ""},
		"a bad signature":  {func() Signed { x := s; x.Assertion.Signature = "***"; return x }(), ErrMalformed, ""},
		"no client data":   {func() Signed { x := s; x.Assertion.ClientDataJSON = ""; return x }(), ErrMalformed, ""},
		"no credential id": {func() Signed { x := s; x.Assertion.CredentialID = ""; return x }(), ErrMalformed, ""},
	} {
		_, _, err := c.s.Parts()
		if !errors.Is(err, c.want) || !strings.Contains(err.Error(), c.says) {
			t.Errorf("%s: got %v, want %v %s", name, err, c.want, c.says)
		}
	}
}

func BenchmarkVerifyES256(b *testing.B) {
	es := newES256(b)
	p := pin(es.key(b))
	a := es.sign(b, good(card()))
	now := signedAt.Add(time.Hour)
	for b.Loop() {
		if err := Verify(p, card(), a, 3523, now); err != nil {
			b.Fatal(err)
		}
	}
}
