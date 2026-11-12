// Package release is how slipdock-runner knows a release is the project's
// (W-2542): a manifest naming each platform's binary and its SHA-256,
// signed with the project's ed25519 key in OpenSSH's signature format
// (`ssh-keygen -Y sign -n slipdock-runner`), and the public key embedded
// in the binary.
//
// OpenSSH's format, so that the install one-liner can check the same
// signature with `ssh-keygen -Y verify`, which macOS, Linux and Windows 10+
// already have, and the daemon can check it with the standard library
// alone (PROTOCOL.sshsig in OpenSSH's source says how it is laid out).
package release

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

// Namespace is the signature's namespace: a signature made for anything
// else with the same key doesn't verify as a release.
const Namespace = "slipdock-runner"

// CLINamespace is the slipdock CLI's (#2669): the escript a server serves
// is signed with the same key in a namespace of its own, so a signature
// of one can't pass for the other.
const CLINamespace = "slipdock-cli"

// SkillsNamespace is the skills archive's (#2784): the archive a server
// serves at /api/skills.tar.gz, signed by the release job with the same
// key in a namespace of its own.
const SkillsNamespace = "slipdock-skills"

const (
	magic      = "SSHSIG"
	sigVersion = 1
	keyType    = "ssh-ed25519"
	armorBegin = "-----BEGIN SSH SIGNATURE-----"
	armorEnd   = "-----END SSH SIGNATURE-----"
)

// ErrNoKey is returned when the binary was built with no release key.
var ErrNoKey = errors.New("this build has no release key, so it can't check an update: install a released slipdock-runner")

// ParsePublicKey reads an ed25519 public key from authorized_keys-style
// text ("ssh-ed25519 AAAA… comment"), skipping blank and # lines. No key
// line is ErrNoKey.
func ParsePublicKey(text string) (ed25519.PublicKey, error) {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != keyType {
			return nil, fmt.Errorf("the release key is not an %s key", keyType)
		}
		blob, err := base64.StdEncoding.DecodeString(fields[1])
		if err != nil {
			return nil, fmt.Errorf("the release key is not base64: %w", err)
		}
		return parseWireKey(blob)
	}
	return nil, ErrNoKey
}

func parseWireKey(blob []byte) (ed25519.PublicKey, error) {
	r := &reader{b: blob}
	typ := r.str()
	key := r.str()
	if r.err != nil || len(r.b) != 0 || string(typ) != keyType || len(key) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("not an %s public key", keyType)
	}
	return ed25519.PublicKey(key), nil
}

// Verify checks an armored OpenSSH signature of message against key, in
// Namespace. Any fault (not armored, another key, another namespace, a
// signature that doesn't match) is an error.
func Verify(key ed25519.PublicKey, message, armored []byte) error {
	return VerifyIn(Namespace, key, message, armored)
}

// VerifyIn is Verify in the namespace ns.
func VerifyIn(ns string, key ed25519.PublicKey, message, armored []byte) error {
	if len(key) == 0 {
		return ErrNoKey
	}
	blob, err := dearmor(armored)
	if err != nil {
		return err
	}
	r := &reader{b: blob}
	pre := r.raw(len(magic))
	version := r.u32()
	pub := r.str()
	sigNS := r.str()
	reserved := r.str()
	hashAlg := r.str()
	sig := r.str()
	if r.err != nil || len(r.b) != 0 || string(pre) != magic {
		return errors.New("the signature is not an SSH signature")
	}
	if version != sigVersion {
		return fmt.Errorf("the signature is version %d, not %d", version, sigVersion)
	}
	signer, err := parseWireKey(pub)
	if err != nil {
		return fmt.Errorf("the signature's key: %w", err)
	}
	if !bytes.Equal(signer, key) {
		return errors.New("the signature was made with another key, not the project's release key")
	}
	if string(sigNS) != ns {
		return fmt.Errorf("the signature is for %q, not %q", sigNS, ns)
	}
	digest, err := hash(string(hashAlg), message)
	if err != nil {
		return err
	}
	sr := &reader{b: sig}
	sigType := sr.str()
	sigBytes := sr.str()
	if sr.err != nil || string(sigType) != keyType || len(sigBytes) != ed25519.SignatureSize {
		return errors.New("the signature is not an ed25519 signature")
	}
	if !ed25519.Verify(key, signedData(ns, reserved, string(hashAlg), digest), sigBytes) {
		return errors.New("the signature does not match: the file is not what the project signed")
	}
	return nil
}

// Sign makes an armored OpenSSH signature of message in Namespace, as
// `ssh-keygen -Y sign -n slipdock-runner` does. The release job signs with
// ssh-keygen itself; this is for the tests.
func Sign(priv ed25519.PrivateKey, message []byte) []byte {
	return SignIn(Namespace, priv, message)
}

// SignIn is Sign in the namespace ns.
func SignIn(ns string, priv ed25519.PrivateKey, message []byte) []byte {
	pub := wireKey(priv.Public().(ed25519.PublicKey))
	digest, _ := hash("sha512", message)
	sig := ed25519.Sign(priv, signedData(ns, nil, "sha512", digest))
	var b bytes.Buffer
	b.WriteString(magic)
	binary.Write(&b, binary.BigEndian, uint32(sigVersion))
	putStr(&b, pub)
	putStr(&b, []byte(ns))
	putStr(&b, nil)
	putStr(&b, []byte("sha512"))
	var s bytes.Buffer
	putStr(&s, []byte(keyType))
	putStr(&s, sig)
	putStr(&b, s.Bytes())
	return armor(b.Bytes())
}

// AuthorizedKey is key as an authorized_keys line, as release_key.pub holds it.
func AuthorizedKey(key ed25519.PublicKey, comment string) string {
	return strings.TrimSpace(keyType + " " + base64.StdEncoding.EncodeToString(wireKey(key)) + " " + comment)
}

func wireKey(key ed25519.PublicKey) []byte {
	var b bytes.Buffer
	putStr(&b, []byte(keyType))
	putStr(&b, key)
	return b.Bytes()
}

func signedData(ns string, reserved []byte, hashAlg string, digest []byte) []byte {
	var b bytes.Buffer
	b.WriteString(magic)
	putStr(&b, []byte(ns))
	putStr(&b, reserved)
	putStr(&b, []byte(hashAlg))
	putStr(&b, digest)
	return b.Bytes()
}

func hash(alg string, message []byte) ([]byte, error) {
	switch alg {
	case "sha512":
		h := sha512.Sum512(message)
		return h[:], nil
	case "sha256":
		h := sha256.Sum256(message)
		return h[:], nil
	default:
		return nil, fmt.Errorf("the signature uses hash %q, not sha512 or sha256", alg)
	}
}

func armor(blob []byte) []byte {
	enc := base64.StdEncoding.EncodeToString(blob)
	var b strings.Builder
	b.WriteString(armorBegin + "\n")
	for len(enc) > 70 {
		b.WriteString(enc[:70] + "\n")
		enc = enc[70:]
	}
	b.WriteString(enc + "\n" + armorEnd + "\n")
	return []byte(b.String())
}

func dearmor(armored []byte) ([]byte, error) {
	text := strings.TrimSpace(strings.ReplaceAll(string(armored), "\r\n", "\n"))
	if !strings.HasPrefix(text, armorBegin) || !strings.HasSuffix(text, armorEnd) {
		return nil, errors.New("the signature is not an armored SSH signature")
	}
	body := strings.Join(strings.Fields(text[len(armorBegin):len(text)-len(armorEnd)]), "")
	blob, err := base64.StdEncoding.DecodeString(body)
	if err != nil {
		return nil, fmt.Errorf("the signature is not base64: %w", err)
	}
	return blob, nil
}

func putStr(b *bytes.Buffer, s []byte) {
	binary.Write(b, binary.BigEndian, uint32(len(s)))
	b.Write(s)
}

// reader reads SSH wire format, remembering the first fault.
type reader struct {
	b   []byte
	err error
}

func (r *reader) raw(n int) []byte {
	if r.err != nil || len(r.b) < n {
		r.err = errors.New("short")
		return nil
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}

func (r *reader) u32() uint32 {
	v := r.raw(4)
	if v == nil {
		return 0
	}
	return binary.BigEndian.Uint32(v)
}

func (r *reader) str() []byte {
	n := r.u32()
	if r.err != nil || uint64(n) > uint64(len(r.b)) {
		r.err = errors.New("short")
		return nil
	}
	return r.raw(int(n))
}
