// Package intent is a spike (#3523), never merged: the check a machine
// could make on a card's text signed by its owner with a passkey, so the
// machine, not the server, decides that the text is the owner's.
//
// What is signed is Canonical(Fields): a versioned, length-prefixed
// encoding of the server's origin, the card's id, when it was signed, and
// the card's title, description and bar, byte for byte. Its SHA-256 is the
// WebAuthn challenge, so the browser's assertion signs
// authenticatorData || SHA-256(clientDataJSON) with clientDataJSON carrying
// that challenge. The machine checks it against public keys pinned in its
// ceiling, using only the standard library.
package intent

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Version is the first line of the canonical text; a new encoding is a new
// version, never a change to this one.
const Version = "slipdock-intent-v1"

// Fields are the signed parts of a card, as the server stores them.
type Fields struct {
	Origin      string // https://slipdock.example.com: the server the owner signed on
	CardID      int64
	SignedAt    time.Time // UTC, second precision
	Title       string
	Description string
	Bar         string
}

// Canonical is the exact bytes whose hash is the challenge. Every field is
// length-prefixed, so no text can pose as the next field, and nothing is
// normalised: the server must hand back the bytes it was given.
func Canonical(f Fields) []byte {
	var b bytes.Buffer
	b.WriteString(Version + "\n")
	field := func(name, v string) {
		b.WriteString(name + " " + strconv.Itoa(len(v)) + "\n" + v + "\n")
	}
	field("origin", f.Origin)
	field("card", strconv.FormatInt(f.CardID, 10))
	field("signed-at", f.SignedAt.UTC().Format(time.RFC3339))
	field("title", f.Title)
	field("description", f.Description)
	field("bar", f.Bar)
	return b.Bytes()
}

// Challenge is the WebAuthn challenge for f: SHA-256 of Canonical(f).
func Challenge(f Fields) []byte {
	h := sha256.Sum256(Canonical(f))
	return h[:]
}

// Assertion is what the browser's navigator.credentials.get() returned,
// kept by the server and handed to the machine with the job.
type Assertion struct {
	CredentialID      []byte
	AuthenticatorData []byte
	ClientDataJSON    []byte
	Signature         []byte
}

// Key is one pinned passkey: its credential id and its public key as
// SubjectPublicKeyInfo DER (what the browser's
// AuthenticatorAttestationResponse.getPublicKey() returns), so the machine
// needs no CBOR to read it.
type Key struct {
	CredentialID []byte
	SPKI         []byte
}

// Pin is what the ceiling would hold: the owner's keys, the relying party
// they belong to, and how old a signature may be.
type Pin struct {
	Origin string // https://slipdock.example.com
	RPID   string // slipdock.example.com
	Keys   []Key
	MaxAge time.Duration // 0: no limit
}

var (
	ErrUnknownKey  = errors.New("intent: signed by a key this machine doesn't pin")
	ErrChallenge   = errors.New("intent: the signature is over other text")
	ErrOrigin      = errors.New("intent: signed on another server")
	ErrNotVerified = errors.New("intent: the passkey didn't verify its user")
	ErrSignature   = errors.New("intent: the signature doesn't verify")
	ErrStale       = errors.New("intent: signed too long ago")
	ErrCard        = errors.New("intent: signed for another card")
)

type clientData struct {
	Type      string `json:"type"`
	Challenge string `json:"challenge"`
	Origin    string `json:"origin"`
}

// Verify says whether a is the pinned owner's signature over f, for the
// job's card, now. Only a nil error may raise the job to the top tier.
func Verify(p Pin, f Fields, a Assertion, jobCard int64, now time.Time) error {
	if f.CardID != jobCard {
		return ErrCard
	}
	if f.Origin != p.Origin {
		return ErrOrigin
	}
	if p.MaxAge > 0 && (now.Sub(f.SignedAt) > p.MaxAge || f.SignedAt.After(now.Add(5*time.Minute))) {
		return ErrStale
	}
	var key *Key
	for i := range p.Keys {
		if bytes.Equal(p.Keys[i].CredentialID, a.CredentialID) {
			key = &p.Keys[i]
		}
	}
	if key == nil {
		return ErrUnknownKey
	}
	var cd clientData
	if err := json.Unmarshal(a.ClientDataJSON, &cd); err != nil {
		return fmt.Errorf("intent: clientDataJSON: %w", err)
	}
	if cd.Type != "webauthn.get" {
		return fmt.Errorf("intent: clientDataJSON type %q", cd.Type)
	}
	if cd.Origin != p.Origin {
		return ErrOrigin
	}
	got, err := base64.RawURLEncoding.DecodeString(cd.Challenge)
	if err != nil || !bytes.Equal(got, Challenge(f)) {
		return ErrChallenge
	}
	ad := a.AuthenticatorData
	if len(ad) < 37 {
		return errors.New("intent: authenticatorData too short")
	}
	rp := sha256.Sum256([]byte(p.RPID))
	if !bytes.Equal(ad[:32], rp[:]) {
		return ErrOrigin
	}
	const up, uv = 0x01, 0x04
	if ad[32]&up == 0 || ad[32]&uv == 0 {
		return ErrNotVerified
	}
	_ = binary.BigEndian.Uint32(ad[33:37]) // sign count: synced passkeys send 0, so it proves nothing here

	cdHash := sha256.Sum256(a.ClientDataJSON)
	signed := append(append([]byte{}, ad...), cdHash[:]...)
	pub, err := x509.ParsePKIXPublicKey(key.SPKI)
	if err != nil {
		return fmt.Errorf("intent: pinned key: %w", err)
	}
	digest := sha256.Sum256(signed)
	switch k := pub.(type) {
	case *ecdsa.PublicKey: // ES256 (COSE -7)
		if !ecdsa.VerifyASN1(k, digest[:], a.Signature) {
			return ErrSignature
		}
	case ed25519.PublicKey: // EdDSA (COSE -8): signs the message itself
		if !ed25519.Verify(k, signed, a.Signature) {
			return ErrSignature
		}
	case *rsa.PublicKey: // RS256 (COSE -257)
		if rsa.VerifyPKCS1v15(k, crypto.SHA256, digest[:], a.Signature) != nil {
			return ErrSignature
		}
	default:
		return fmt.Errorf("intent: pinned key of type %T", pub)
	}
	return nil
}
