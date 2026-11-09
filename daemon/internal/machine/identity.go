package machine

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Identity is the machine's own key pair, made once at the first init and
// kept through --replace. Its fingerprint is what init prints and the
// approval page shows, so the person approving can tell it is this machine.
type Identity struct {
	Private ed25519.PrivateKey
}

// LoadOrCreateIdentity reads dir's identity, making one if there is none.
func LoadOrCreateIdentity(dir string) (Identity, error) {
	path := filepath.Join(dir, IdentityFile)
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		seed, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return Identity{}, fmt.Errorf("%s is damaged: delete it and run init --replace", path)
		}
		return Identity{Private: ed25519.NewKeyFromSeed(seed)}, nil
	case errors.Is(err, os.ErrNotExist):
		if err := ensureDir(dir); err != nil {
			return Identity{}, err
		}
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return Identity{}, err
		}
		if err := WriteSecret(path, []byte(hex.EncodeToString(priv.Seed())+"\n")); err != nil {
			return Identity{}, err
		}
		return Identity{Private: priv}, nil
	default:
		return Identity{}, err
	}
}

// Fingerprint is the first 16 bytes of the SHA-256 of the public key, as
// eight groups of four hex digits: short enough to compare by eye.
func (id Identity) Fingerprint() string {
	sum := sha256.Sum256(id.Private.Public().(ed25519.PublicKey))
	h := hex.EncodeToString(sum[:16])
	groups := make([]string, 0, 8)
	for i := 0; i < len(h); i += 4 {
		groups = append(groups, h[i:i+4])
	}
	return strings.Join(groups, ":")
}
