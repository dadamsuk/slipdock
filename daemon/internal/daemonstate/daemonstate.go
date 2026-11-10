// Package daemonstate is what the running daemon writes down about itself
// for `slipdock-runner status` to read back with no server call (#2652):
// daemon-state.json in its directory (the process, when it started and
// stopped, and its last contact with the server), and each runner's
// jobs/<runner>/job.json (the job it holds or last held).
package daemonstate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// File is the daemon's state, in its directory.
const File = "daemon-state.json"

// JobFile is a runner's last job, beside its job.log.
const JobFile = "job.json"

// Daemon is File's shape.
type Daemon struct {
	PID     int        `json:"pid"`
	Version string     `json:"version"`
	Started time.Time  `json:"started"`
	Stopped *time.Time `json:"stopped,omitempty"`
	// LastContact is when the server last answered the enrolment check;
	// Online whether the latest check reached it, and LastError why not.
	LastContact *time.Time `json:"last_contact,omitempty"`
	Online      bool       `json:"online"`
	LastError   string     `json:"last_error,omitempty"`
}

// Job is JobFile's shape: the job a runner holds, or held last.
type Job struct {
	ID       int64      `json:"id"`
	CardID   int64      `json:"card_id"`
	Kind     string     `json:"kind"`
	Started  time.Time  `json:"started"`
	Finished *time.Time `json:"finished,omitempty"`
	// Status is how it ended: the status reported to the server, or
	// "stopped" when the daemon stopped while it ran.
	Status string `json:"status,omitempty"`
}

// Load reads dir's daemon state; none is nil.
func Load(dir string) (*Daemon, error) {
	var d Daemon
	if ok, err := readJSON(filepath.Join(dir, File), &d); !ok {
		return nil, err
	}
	return &d, nil
}

// Save writes dir's daemon state.
func Save(dir string, d Daemon) error {
	return writeJSON(filepath.Join(dir, File), d)
}

// JobPath is runner id's job file under jobsDir.
func JobPath(jobsDir string, runnerID int64) string {
	return filepath.Join(jobsDir, fmt.Sprint(runnerID), JobFile)
}

// LoadJob reads runner id's last job; none is nil.
func LoadJob(jobsDir string, runnerID int64) (*Job, error) {
	var j Job
	if ok, err := readJSON(JobPath(jobsDir, runnerID), &j); !ok {
		return nil, err
	}
	return &j, nil
}

// SaveJob writes runner id's job file.
func SaveJob(jobsDir string, runnerID int64, j Job) error {
	return writeJSON(JobPath(jobsDir, runnerID), j)
}

func readJSON(path string, v any) (bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	if err := json.Unmarshal(data, v); err != nil {
		return false, fmt.Errorf("%s: %w", path, err)
	}
	return true, nil
}

// writeJSON writes v whole to a temporary file and renames it into place,
// so a reader never sees half of one.
func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
