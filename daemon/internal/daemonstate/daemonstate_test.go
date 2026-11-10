package daemonstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTheStateFilesRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if d, err := Load(dir); d != nil || err != nil {
		t.Fatalf("none yet: %v %v", d, err)
	}
	at := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	if err := Save(dir, Daemon{PID: 42, Version: "v1.2.3", Started: at, LastContact: &at, Online: true}); err != nil {
		t.Fatal(err)
	}
	d, err := Load(dir)
	if err != nil || d.PID != 42 || d.Version != "v1.2.3" || !d.Started.Equal(at) || !d.Online || d.Stopped != nil {
		t.Fatalf("%+v %v", d, err)
	}

	jobs := filepath.Join(dir, "jobs")
	if j, err := LoadJob(jobs, 21); j != nil || err != nil {
		t.Fatalf("no job yet: %v %v", j, err)
	}
	if err := SaveJob(jobs, 21, Job{ID: 7, CardID: 42, Kind: "claude", Started: at}); err != nil {
		t.Fatal(err)
	}
	if j, err := LoadJob(jobs, 21); err != nil || j.ID != 7 || j.CardID != 42 || j.Finished != nil {
		t.Fatalf("%+v %v", j, err)
	}
	// Nothing left behind but the file.
	entries, _ := os.ReadDir(filepath.Join(jobs, "21"))
	if len(entries) != 1 || entries[0].Name() != JobFile {
		t.Fatalf("left behind: %v", entries)
	}

	os.WriteFile(filepath.Join(dir, File), []byte("{broken"), 0o600)
	if _, err := Load(dir); err == nil || !strings.Contains(err.Error(), File) {
		t.Fatalf("a broken file: %v", err)
	}
}
