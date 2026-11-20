// Package intent is the canonical text of a card signed by its board's
// owner with a passkey (#3532): what the server and the daemon both hash
// into the WebAuthn challenge. The daemon's check of the assertion against
// pinned keys builds on it (#3533; the spike's prototype, #3523, W-2910).
//
// Canonical(Fields) is a versioned, length-prefixed encoding of the server's
// origin, the card's id, when it was signed, and the card's title,
// description and bar, byte for byte. The server's encoder is
// Slipdock.Intent.canonical/1; both are tested against
// testdata/canonical-v1.json, so the two can't drift apart.
package intent

import (
	"bytes"
	"crypto/sha256"
	"strconv"
	"time"
)

// Version is the first line of the canonical text; a new encoding is a new
// version, never a change to this one.
const Version = "slipdock-intent-v1"

// Fields are the signed parts of a card, as the server returns them.
type Fields struct {
	Origin      string // https://slipdock.example.com: the server the owner signed on
	CardID      int64
	SignedAt    time.Time // UTC, second precision
	Title       string
	Description string
	Bar         string
}

// Canonical is the exact bytes whose hash is the challenge. Every field is
// its name, a space, its length in bytes, a newline, its bytes and a
// newline, so no text can pose as the next field; nothing is normalised.
func Canonical(f Fields) []byte {
	var b bytes.Buffer
	b.WriteString(Version + "\n")
	field := func(name, v string) {
		b.WriteString(name + " " + strconv.Itoa(len(v)) + "\n" + v + "\n")
	}
	field("origin", f.Origin)
	field("card", strconv.FormatInt(f.CardID, 10))
	field("signed-at", f.SignedAt.UTC().Truncate(time.Second).Format(time.RFC3339))
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
