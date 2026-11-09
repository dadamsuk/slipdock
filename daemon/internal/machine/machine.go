// Package machine holds what the daemon keeps on disk about its machine: the
// enrolment (server, machine id, the boards it serves), the machine key, the
// machine's identity key and fingerprint, and the ceiling (W-2541): the
// limits the machine sets itself, which the server never reads or writes.
//
// Everything lives in one directory, Dir. The machine key and the identity
// are written owner-read-only (0600, in a 0700 directory); on Windows,
// where Unix modes don't apply, the directory is under the user's own
// profile, which only that account and administrators can read.
package machine

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The files in Dir.
const (
	StateFile    = "machine.json"
	KeyFile      = "machine-key"
	IdentityFile = "identity"
	CeilingFile  = "ceiling.json"
)

// HomeEnv overrides Dir, for a second daemon on one account and for tests.
const HomeEnv = "SLIPDOCK_RUNNER_HOME"

// Dir is where the daemon keeps its files: $SLIPDOCK_RUNNER_HOME if set,
// else slipdock-runner/machine under the user's config directory
// (~/.config on Linux, ~/Library/Application Support on macOS, %AppData% on
// Windows). The machine/ subdirectory keeps it apart from the shell runner's
// config files, which live in slipdock-runner/ until they retire.
func Dir(getenv func(string) string) (string, error) {
	if dir := getenv(HomeEnv); dir != "" {
		return filepath.Abs(dir)
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("no config directory for this account: %w (set %s)", err, HomeEnv)
	}
	return filepath.Join(base, "slipdock-runner", "machine"), nil
}

// State is what enrolment told the daemon about itself.
type State struct {
	Server      string    `json:"server"`
	MachineID   int64     `json:"machine_id"`
	Name        string    `json:"name"`
	Boards      []int64   `json:"boards"`
	EnrolledVia string    `json:"enrolled_via"`
	EnrolledAt  time.Time `json:"enrolled_at"`
}

// ErrNotEnrolled is returned when the directory holds no machine key.
var ErrNotEnrolled = errors.New("this machine is not enrolled: run slipdock-runner init")

// Enrolled says whether dir already holds a machine key.
func Enrolled(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, KeyFile))
	return err == nil
}

// Save writes the enrolment: the state, and the machine key owner-read-only.
func Save(dir string, st State, key string) error {
	if key == "" {
		return errors.New("the server sent no machine key")
	}
	if err := ensureDir(dir); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := WriteSecret(filepath.Join(dir, KeyFile), []byte(key+"\n")); err != nil {
		return err
	}
	return writeFile(filepath.Join(dir, StateFile), append(data, '\n'), 0o644)
}

// Load reads the enrolment and the machine key.
func Load(dir string) (State, string, error) {
	var st State
	key, err := os.ReadFile(filepath.Join(dir, KeyFile))
	if errors.Is(err, os.ErrNotExist) {
		return st, "", ErrNotEnrolled
	} else if err != nil {
		return st, "", err
	}
	data, err := os.ReadFile(filepath.Join(dir, StateFile))
	if err != nil {
		return st, "", fmt.Errorf("the machine key is there but %s isn't readable: %w (run init --replace)", StateFile, err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return st, "", fmt.Errorf("%s is not valid JSON: %w", StateFile, err)
	}
	k := string(trimSpace(key))
	if k == "" {
		return st, "", fmt.Errorf("%s is empty: run init --replace", KeyFile)
	}
	return st, k, nil
}

func trimSpace(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r' || b[len(b)-1] == ' ') {
		b = b[:len(b)-1]
	}
	return b
}

func ensureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// MkdirAll leaves an existing directory's mode alone: tighten it.
	return os.Chmod(dir, 0o700)
}

// WriteSecret writes data readable by its owner only, replacing path
// atomically so a reader never sees half a key.
func WriteSecret(path string, data []byte) error {
	return writeFile(path, data, 0o600)
}

func writeFile(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(mode); err != nil && !isWindows() {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
