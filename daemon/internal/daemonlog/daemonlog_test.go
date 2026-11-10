package daemonlog

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var at = time.Date(2026, 11, 10, 9, 30, 0, 0, time.UTC)

func TestSplitTakesTheMarkerOff(t *testing.T) {
	for _, tc := range []struct {
		in    string
		level Level
		out   string
	}{
		{"warn: can't reach %s", Warn, "can't reach %s"},
		{"error: refused", Error, "refused"},
		{"debug: detail", Debug, "detail"},
		{"enrolled as box", Info, "enrolled as box"},
		// Only a marker at the very start, followed by a space.
		{"a warn: inside", Info, "a warn: inside"},
		{"warn:no space", Info, "warn:no space"},
		{"WARN: shouting", Info, "WARN: shouting"},
	} {
		level, out := Split(tc.in)
		if level != tc.level || out != tc.out {
			t.Errorf("Split(%q) = %v %q, want %v %q", tc.in, level, out, tc.level, tc.out)
		}
	}
}

func TestParseLevel(t *testing.T) {
	for in, want := range map[string]Level{"": Info, "debug": Debug, "INFO": Info, "Warn": Warn, "warning": Warn, " error ": Error} {
		if got, err := ParseLevel(in); err != nil || got != want {
			t.Errorf("ParseLevel(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := ParseLevel("loud"); err == nil || !strings.Contains(err.Error(), `"loud"`) {
		t.Errorf("ParseLevel(loud) = %v", err)
	}
	if Level(9).String() != "INFO" || Error.String() != "ERROR" {
		t.Errorf("String: %q %q", Level(9), Error)
	}
}

// The logger tags each line, drops what is below its level, and writes
// both to its writer and to daemon.log in the directory.
func TestTheLoggerFiltersAndWritesBoth(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	l, err := New(Warn, &out, dir)
	if err != nil {
		t.Fatal(err)
	}
	l.Now = func() time.Time { return at }
	l.Printf("enrolled as %s", "box")
	l.Printf("debug: nothing newer")
	l.Printf("warn: can't reach the server: %v", "timeout")
	l.Printf("error: REFUSED an update")
	l.Close()
	want := "2026-11-10T09:30:00Z WARN  can't reach the server: timeout\n2026-11-10T09:30:00Z ERROR REFUSED an update\n"
	if out.String() != want {
		t.Fatalf("out:\n%s\nwant:\n%s", out.String(), want)
	}
	file, _ := os.ReadFile(filepath.Join(dir, File))
	if string(file) != want {
		t.Fatalf("daemon.log:\n%s", file)
	}
	if st, _ := os.Stat(filepath.Join(dir, File)); st.Mode().Perm()&0o077 != 0 && os.PathSeparator == '/' {
		t.Fatalf("daemon.log is %v: owner-only", st.Mode().Perm())
	}

	// At debug, everything; with no directory, no file.
	out.Reset()
	l, _ = New(Debug, &out, "")
	l.Now = func() time.Time { return at }
	l.Printf("debug: a detail")
	l.Printf("multi\nline\n")
	if out.String() != "2026-11-10T09:30:00Z DEBUG a detail\n2026-11-10T09:30:00Z INFO  multi\nline\n" {
		t.Fatalf("debug:\n%s", out.String())
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
}

// daemon.log is moved aside once it would pass MaxSize, the one before it
// dropped, so the log never holds much more than twice MaxSize.
func TestDaemonLogIsRotated(t *testing.T) {
	old := MaxSize
	MaxSize = 200
	t.Cleanup(func() { MaxSize = old })
	dir := t.TempDir()
	l, err := New(Info, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	l.Now = func() time.Time { return at }
	for i := 0; i < 12; i++ {
		l.Printf("line %02d %s", i, strings.Repeat("x", 20))
	}
	l.Close()
	for _, name := range []string{File, Rotated} {
		st, err := os.Stat(filepath.Join(dir, name))
		if err != nil || st.Size() > 200 {
			t.Fatalf("%s: %v %v", name, st, err)
		}
	}
	lines, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	// The rotated file comes first, so the lines are in order and the last
	// is the newest.
	if len(lines) < 4 || !strings.Contains(lines[len(lines)-1].Text, "line 11") {
		t.Fatalf("lines: %+v", lines)
	}
	for i := 1; i < len(lines); i++ {
		if lines[i].Text < lines[i-1].Text {
			t.Fatalf("out of order: %q before %q", lines[i-1].Text, lines[i].Text)
		}
	}
	if strings.Contains(lines[0].Text, "line 00") {
		t.Fatalf("the oldest lines were dropped with the file before the rotated one: %+v", lines[0])
	}

	// A file already there is appended to, its size counted.
	l, _ = New(Info, nil, dir)
	l.Now = func() time.Time { return at }
	l.Printf("after a restart")
	l.Close()
	if lines, _ := Read(dir); lines[len(lines)-1].Text != "after a restart" {
		t.Fatalf("after a restart: %+v", lines[len(lines)-1])
	}
}

// Read gives a line that ran over several the time and level of the one
// it continues; a line with no stamp at the start is INFO.
func TestReadContinuedLines(t *testing.T) {
	lines, err := ReadFrom(strings.NewReader("stray\n2026-11-10T09:30:00Z WARN  first\n  second\n2026-11-10T09:31:00Z DEBUG third\n"), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 4 {
		t.Fatalf("%+v", lines)
	}
	if lines[0].Level != Info || !lines[0].Continued || lines[0].Raw != "stray" {
		t.Errorf("stray: %+v", lines[0])
	}
	if lines[1].Level != Warn || lines[1].Text != "first" || !lines[1].At.Equal(at) {
		t.Errorf("first: %+v", lines[1])
	}
	if lines[2].Level != Warn || !lines[2].Continued || !lines[2].At.Equal(at) || lines[2].Raw != "  second" {
		t.Errorf("second: %+v", lines[2])
	}
	if lines[3].Level != Debug || lines[3].Text != "third" {
		t.Errorf("third: %+v", lines[3])
	}
	// A stamp followed by a word that isn't a level is a continued line.
	if l := Parse("2026-11-10T09:30:00Z LOUD x"); !l.Continued {
		t.Errorf("not a level: %+v", l)
	}
	if lines, err := Read(t.TempDir()); err != nil || len(lines) != 0 {
		t.Errorf("no log: %v %v", lines, err)
	}
}
