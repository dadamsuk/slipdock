// Package update is how slipdock-runner replaces itself with a newer
// release (W-2542): it fetches the release's manifest and signature from
// wherever the machine says releases come from, checks the signature
// against the key embedded in this binary, and only then downloads the
// binary for this platform, checks its SHA-256 against the signed manifest
// and puts it in place of the running one. Any host may serve a release;
// none can author one.
package update

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

// DefaultSource is where releases come from unless the machine says
// otherwise: the latest GitHub Release's files.
const DefaultSource = "https://github.com/dadamsuk/slipdock/releases/latest/download"

// File is update.json in the daemon's directory: the machine's update
// settings and how the last check went.
const File = "update.json"

// Modes.
const (
	Auto   = "auto"   // install a newer release, then restart
	Manual = "manual" // only report that one exists
)

// Outcomes of a check.
const (
	Current   = "current"   // nothing newer
	Available = "available" // newer, not installed (manual, or --check)
	Installed = "installed"
	Refused   = "refused" // a signature or checksum didn't verify
	Failed    = "failed"  // couldn't fetch or write: try again later
)

// maxManifest bounds what is read before the signature is checked.
const maxManifest = 1 << 20

// Settings is update.json.
type Settings struct {
	Mode   string `json:"mode,omitempty"`
	Source string `json:"source,omitempty"`
	Last   *Check `json:"last,omitempty"`
}

// Check is how one check went.
type Check struct {
	At      time.Time `json:"at"`
	Current string    `json:"current"`
	Latest  string    `json:"latest,omitempty"`
	Outcome string    `json:"outcome"`
	Reason  string    `json:"reason,omitempty"`
	Source  string    `json:"source"`
}

// ModeOrDefault is the mode, auto when unset.
func (s Settings) ModeOrDefault() string {
	if s.Mode == "" {
		return Auto
	}
	return s.Mode
}

// SourceOrDefault is the source, DefaultSource when unset.
func (s Settings) SourceOrDefault() string {
	if s.Source == "" {
		return DefaultSource
	}
	return strings.TrimRight(s.Source, "/")
}

// Load reads update.json from dir; none is the defaults.
func Load(dir string) (Settings, error) {
	var s Settings
	data, err := os.ReadFile(filepath.Join(dir, File))
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	} else if err != nil {
		return s, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, fmt.Errorf("%s is not valid JSON: %w", File, err)
	}
	if s.Mode != "" && s.Mode != Auto && s.Mode != Manual {
		return s, fmt.Errorf("%s: mode is %q, not %s or %s", File, s.Mode, Auto, Manual)
	}
	return s, nil
}

// Save writes update.json to dir.
func Save(dir string, s Settings) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, "."+File+".tmp")
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, File))
}

// RefusedError is an update that didn't verify: a bad or missing
// signature, a manifest that isn't the project's, a binary whose checksum
// doesn't match. Never installed, always reported.
type RefusedError struct{ Reason string }

func (e *RefusedError) Error() string { return "refused: " + e.Reason }

// IsRefused says whether err is a RefusedError.
func IsRefused(err error) bool {
	var r *RefusedError
	return errors.As(err, &r)
}

// Updater checks and installs releases for one binary.
type Updater struct {
	HTTP      *http.Client
	Source    string            // base URL: Source/release.json, Source/<file>
	Key       ed25519.PublicKey // the project's release key
	Current   string            // this binary's version
	GOOS      string
	GOARCH    string
	Exe       string // the binary to replace
	UserAgent string
}

// Offer is a newer release for this platform, verified.
type Offer struct {
	Manifest release.Manifest
	File     release.File
}

// Check fetches and verifies the manifest. A nil offer means nothing newer.
func (u Updater) Check(ctx context.Context) (*Offer, string, error) {
	if len(u.Key) == 0 {
		return nil, "", &RefusedError{release.ErrNoKey.Error()}
	}
	data, err := u.get(ctx, release.ManifestFile, maxManifest)
	if err != nil {
		return nil, "", err
	}
	sig, err := u.get(ctx, release.SignatureFile, 64<<10)
	if errors.Is(err, errNotFound) {
		return nil, "", &RefusedError{"the release has no signature (" + release.SignatureFile + ")"}
	} else if err != nil {
		return nil, "", err
	}
	m, err := release.VerifyManifest(u.Key, data, sig)
	if err != nil {
		return nil, "", &RefusedError{release.ManifestFile + ": " + err.Error()}
	}
	newer, err := release.Newer(m.Version, u.Current)
	if err != nil {
		return nil, m.Version, err
	}
	if !newer {
		return nil, m.Version, nil
	}
	f, ok := m.For(u.GOOS, u.GOARCH)
	if !ok {
		return nil, m.Version, fmt.Errorf("%s has no build for %s/%s", m.Version, u.GOOS, u.GOARCH)
	}
	return &Offer{Manifest: m, File: f}, m.Version, nil
}

// Install downloads the offer's binary, checks it against the signed
// manifest, and puts it in place of u.Exe. Nothing is written over the
// running binary until the whole file has been checked.
func (u Updater) Install(ctx context.Context, o *Offer) error {
	data, err := u.get(ctx, o.File.Name, o.File.Size+1)
	if err != nil {
		return err
	}
	if int64(len(data)) != o.File.Size {
		return &RefusedError{fmt.Sprintf("%s is %d bytes, but the signed manifest says %d", o.File.Name, len(data), o.File.Size)}
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != o.File.SHA256 {
		return &RefusedError{o.File.Name + "'s SHA-256 is not the one the signed manifest gives: the file has been changed"}
	}
	return replace(u.Exe, data)
}

var errNotFound = errors.New("not found")

func (u Updater) get(ctx context.Context, name string, limit int64) ([]byte, error) {
	url := strings.TrimRight(u.Source, "/") + "/" + name
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if u.UserAgent != "" {
		req.Header.Set("User-Agent", u.UserAgent)
	}
	client := u.HTTP
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("fetching %s: %w", name, errNotFound)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetching %s: %s", name, resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", name, err)
	}
	return data, nil
}

// replace puts data where exe is, as one rename, so a crash leaves the old
// binary or the new one, never half of one. Windows can't replace a
// running binary but can rename it: the old one is moved aside to
// exe.old, which Cleanup removes on the next start.
func replace(exe string, data []byte) error {
	dir := filepath.Dir(exe)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(exe)+".new-*")
	if err != nil {
		return fmt.Errorf("writing the update beside %s: %w", exe, err)
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o755); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		old := exe + ".old"
		os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			return fmt.Errorf("moving the running binary aside: %w", err)
		}
		if err := os.Rename(name, exe); err != nil {
			os.Rename(old, exe)
			return err
		}
		return nil
	}
	return os.Rename(name, exe)
}

// Cleanup removes what a Windows update left beside exe.
func Cleanup(exe string) { os.Remove(exe + ".old") }

// Run is one check as the daemon does it: verify, and in auto mode (or
// when install is true) install. It records the outcome in the check it
// returns; installed says the binary was replaced and the process should
// restart to run it.
func (u Updater) Run(ctx context.Context, install bool, now time.Time) (Check, error) {
	c := Check{At: now.UTC(), Current: u.Current, Source: u.Source}
	offer, latest, err := u.Check(ctx)
	c.Latest = latest
	switch {
	case err != nil:
		c.Outcome, c.Reason = outcome(err), err.Error()
		return c, err
	case offer == nil:
		c.Outcome = Current
		return c, nil
	case !install:
		c.Outcome = Available
		return c, nil
	}
	if err := u.Install(ctx, offer); err != nil {
		c.Outcome, c.Reason = outcome(err), err.Error()
		return c, err
	}
	c.Outcome = Installed
	return c, nil
}

func outcome(err error) string {
	if IsRefused(err) {
		return Refused
	}
	return Failed
}
