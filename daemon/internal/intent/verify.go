package intent

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Key is one pinned passkey of a board's owner (#3533): its credential id,
// its public key as SubjectPublicKeyInfo DER (so no CBOR is needed to read
// it), and the origin and relying party id it signs for. The person at the
// machine pins it (slipdock-runner trust-owner); the server never does.
type Key struct {
	CredentialID []byte
	SPKI         []byte
	Origin       string // https://slipdock.example.com
	RPID         string // slipdock.example.com
}

// Pin is the machine's pinned owner keys, and how old a signature may be.
type Pin struct {
	Keys   []Key
	MaxAge time.Duration
}

// Assertion is what the browser's navigator.credentials.get() returned
// when the owner signed, as the server keeps it.
type Assertion struct {
	CredentialID      []byte
	AuthenticatorData []byte
	ClientDataJSON    []byte
	Signature         []byte
}

// Why a signature doesn't count. Each is a reason a job is held below the
// owner tier, and says so in the logs.
var (
	ErrUnsigned    = errors.New("the card is not signed by its owner")
	ErrVersion     = errors.New("the signed text is in an encoding this daemon doesn't know")
	ErrMalformed   = errors.New("the signed text or its signature is malformed")
	ErrCard        = errors.New("the signature is for another card")
	ErrUnknownKey  = errors.New("signed by a key this machine doesn't pin")
	ErrOrigin      = errors.New("signed on another server")
	ErrRPID        = errors.New("signed for another relying party")
	ErrStale       = errors.New("signed longer ago than the ceiling allows, or in the future")
	ErrType        = errors.New("the signature is not a WebAuthn assertion")
	ErrChallenge   = errors.New("the signature is over other text")
	ErrNotVerified = errors.New("the passkey didn't check the user was present and verified")
	ErrSignature   = errors.New("the signature doesn't verify against the pinned key")
)

// clockSkew is how far in the future a signed-at may be and still count.
const clockSkew = 5 * time.Minute

type clientData struct {
	Type        string `json:"type"`
	Challenge   string `json:"challenge"`
	Origin      string `json:"origin"`
	CrossOrigin bool   `json:"crossOrigin"`
}

// Verify says whether a is the signature of one of p's keys over f, for the
// job's card, at now: the challenge is SHA-256 of Canonical(f), the origin
// and relying party are the pinned key's, the passkey checked the user was
// present and verified them, and f was signed within p.MaxAge (which must be
// set). Only a nil error may let a job run at the owner tier.
func Verify(p Pin, f Fields, a Assertion, jobCard int64, now time.Time) error {
	if jobCard <= 0 || f.CardID != jobCard {
		return ErrCard
	}
	var key *Key
	for i := range p.Keys {
		if len(a.CredentialID) > 0 && bytes.Equal(p.Keys[i].CredentialID, a.CredentialID) {
			key = &p.Keys[i]
			break
		}
	}
	if key == nil {
		return ErrUnknownKey
	}
	if f.Origin != key.Origin {
		return ErrOrigin
	}
	if p.MaxAge <= 0 || now.Sub(f.SignedAt) > p.MaxAge || f.SignedAt.After(now.Add(clockSkew)) {
		return ErrStale
	}
	var cd clientData
	if err := json.Unmarshal(a.ClientDataJSON, &cd); err != nil {
		return ErrMalformed
	}
	if cd.Type != "webauthn.get" {
		return ErrType
	}
	if cd.Origin != key.Origin || cd.CrossOrigin {
		return ErrOrigin
	}
	got, err := decode64(cd.Challenge)
	if err != nil || !bytes.Equal(got, Challenge(f)) {
		return ErrChallenge
	}
	ad := a.AuthenticatorData
	if len(ad) < 37 {
		return ErrMalformed
	}
	rp := sha256.Sum256([]byte(key.RPID))
	if !bytes.Equal(ad[:32], rp[:]) {
		return ErrRPID
	}
	const up, uv = 0x01, 0x04
	if ad[32]&up == 0 || ad[32]&uv == 0 {
		return ErrNotVerified
	}
	// The sign count (ad[33:37]) is not checked: synced passkeys always
	// send 0, so it proves nothing.
	cdHash := sha256.Sum256(a.ClientDataJSON)
	signed := append(append([]byte{}, ad...), cdHash[:]...)
	pub, _, err := ParseKey(key.SPKI)
	if err != nil {
		return fmt.Errorf("the pinned key: %w", err)
	}
	digest := sha256.Sum256(signed)
	switch k := pub.(type) {
	case *ecdsa.PublicKey: // ES256 (COSE -7)
		if !ecdsa.VerifyASN1(k, digest[:], a.Signature) {
			return ErrSignature
		}
	case ed25519.PublicKey: // EdDSA (COSE -8) signs the message itself
		if !ed25519.Verify(k, signed, a.Signature) {
			return ErrSignature
		}
	case *rsa.PublicKey: // RS256 (COSE -257)
		if rsa.VerifyPKCS1v15(k, crypto.SHA256, digest[:], a.Signature) != nil {
			return ErrSignature
		}
	default:
		return ErrSignature
	}
	return nil
}

// ParseKey reads a passkey's SubjectPublicKeyInfo DER and names its
// algorithm: ES256 (ECDSA on P-256), EdDSA (Ed25519) or RS256 (RSA of at
// least 2048 bits), the three the server's passkeys offer. Any other key
// is refused.
func ParseKey(spki []byte) (crypto.PublicKey, string, error) {
	pub, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		return nil, "", fmt.Errorf("not a public key: %w", err)
	}
	switch k := pub.(type) {
	case *ecdsa.PublicKey:
		if k.Curve != elliptic.P256() {
			return nil, "", errors.New("an ECDSA key not on P-256")
		}
		return k, "ES256", nil
	case ed25519.PublicKey:
		return k, "EdDSA", nil
	case *rsa.PublicKey:
		if k.N.BitLen() < 2048 {
			return nil, "", fmt.Errorf("an RSA key of %d bits (2048 at least)", k.N.BitLen())
		}
		return k, "RS256", nil
	}
	return nil, "", fmt.Errorf("a key of type %T", pub)
}

// Fingerprint is a key's fingerprint as the server shows it: sha256: and
// the hex of SHA-256 over its SPKI DER.
func Fingerprint(spki []byte) string {
	h := sha256.Sum256(spki)
	return "sha256:" + hex.EncodeToString(h[:])
}

// Decode64 reads base64url, padded or not, as the server writes it.
func Decode64(s string) ([]byte, error) { return decode64(s) }

func decode64(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}

// Signed is GET /api/runner/jobs/:id/intent's answer (#3532): the job's
// card text as its owner signed it, uncut, with the passkey's assertion;
// or signed false and the card's state (unsigned, edited). Every field is
// the server's word until Verify checks it.
type Signed struct {
	Signed      bool   `json:"signed"`
	State       string `json:"state"`
	Version     string `json:"version"`
	Origin      string `json:"origin"`
	CardID      int64  `json:"card_id"`
	SignedAt    string `json:"signed_at"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Bar         string `json:"bar"`
	Assertion   struct {
		CredentialID      string `json:"credential_id"`
		AuthenticatorData string `json:"authenticator_data"`
		ClientDataJSON    string `json:"client_data_json"`
		Signature         string `json:"signature"`
	} `json:"assertion"`
}

// Parts are the signed fields and the assertion, read from s: ErrUnsigned
// (with the card's state) when the server says it isn't signed, ErrVersion
// for another encoding, ErrMalformed for what can't be read. The rp_id and
// challenge the server sends are not read: the pinned key's rp id and the
// daemon's own hash of the text are what count.
func (s Signed) Parts() (Fields, Assertion, error) {
	if !s.Signed {
		state := s.State
		if state == "" {
			state = "unsigned"
		}
		return Fields{}, Assertion{}, fmt.Errorf("%w (%s)", ErrUnsigned, state)
	}
	if s.Version != Version {
		return Fields{}, Assertion{}, ErrVersion
	}
	at, err := time.Parse(time.RFC3339, s.SignedAt)
	if err != nil {
		return Fields{}, Assertion{}, ErrMalformed
	}
	var a Assertion
	for _, part := range []struct {
		in  string
		out *[]byte
	}{
		{s.Assertion.CredentialID, &a.CredentialID},
		{s.Assertion.AuthenticatorData, &a.AuthenticatorData},
		{s.Assertion.ClientDataJSON, &a.ClientDataJSON},
		{s.Assertion.Signature, &a.Signature},
	} {
		b, err := decode64(part.in)
		if err != nil || len(b) == 0 {
			return Fields{}, Assertion{}, ErrMalformed
		}
		*part.out = b
	}
	f := Fields{Origin: s.Origin, CardID: s.CardID, SignedAt: at, Title: s.Title, Description: s.Description, Bar: s.Bar}
	return f, a, nil
}
