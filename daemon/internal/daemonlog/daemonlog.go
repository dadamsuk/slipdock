// Package daemonlog is the daemon's levelled log (#2652): each line tagged
// DEBUG, INFO, WARN or ERROR, written to stderr (or run's --log file) and
// to daemon.log in the daemon's directory on every platform, capped and
// rotated once, so `slipdock-runner log` reads the same file everywhere.
//
// Callers keep a plain func(format, args...) logger. A format that starts
// with a level marker ("debug: ", "warn: ", "error: ") is logged at that
// level, the marker dropped; any other is INFO.
package daemonlog

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// File is the daemon's own log, in its directory; Rotated is the one
// before it.
const (
	File    = "daemon.log"
	Rotated = "daemon.log.1"
)

// MaxSize is how big daemon.log grows before it is rotated to Rotated,
// so the two together never hold much more than twice this.
var MaxSize int64 = 5 << 20

// Level is how much a line matters.
type Level int

// The levels, least first.
const (
	Debug Level = iota
	Info
	Warn
	Error
)

var names = []string{"DEBUG", "INFO", "WARN", "ERROR"}

func (l Level) String() string {
	if l < Debug || l > Error {
		return "INFO"
	}
	return names[l]
}

// ParseLevel reads debug, info, warn or error, in any case. "" is info.
func ParseLevel(s string) (Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return Debug, nil
	case "", "info":
		return Info, nil
	case "warn", "warning":
		return Warn, nil
	case "error":
		return Error, nil
	}
	return Info, fmt.Errorf("log level %q is not debug, info, warn or error", s)
}

// Split takes a level marker off the front of a format: "warn: x" is
// (Warn, "x"). A format with none is (Info, format).
func Split(format string) (Level, string) {
	for _, m := range []struct {
		prefix string
		level  Level
	}{{"debug: ", Debug}, {"warn: ", Warn}, {"error: ", Error}} {
		if strings.HasPrefix(format, m.prefix) {
			return m.level, format[len(m.prefix):]
		}
	}
	return Info, format
}

// Logger writes levelled lines at or above Min to Out and to the daemon's
// daemon.log. Safe for concurrent use.
type Logger struct {
	Min Level
	Now func() time.Time

	mu   sync.Mutex
	out  io.Writer
	file *capped
}

// New is a logger writing to out and, when dir isn't "", to dir's
// daemon.log, appended to.
func New(min Level, out io.Writer, dir string) (*Logger, error) {
	l := &Logger{Min: min, Now: time.Now, out: out}
	if dir != "" {
		f, err := openCapped(filepath.Join(dir, File), filepath.Join(dir, Rotated))
		if err != nil {
			return nil, err
		}
		l.file = f
	}
	return l, nil
}

// Printf logs one message, at the level its format's marker says.
func (l *Logger) Printf(format string, a ...any) {
	level, format := Split(format)
	l.Log(level, fmt.Sprintf(format, a...))
}

// Log writes msg at level, if level is at or above Min.
func (l *Logger) Log(level Level, msg string) {
	if level < l.Min {
		return
	}
	line := Format(l.Now(), level, msg)
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.out != nil {
		io.WriteString(l.out, line)
	}
	if l.file != nil {
		l.file.write(line)
	}
}

// Close closes daemon.log.
func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.f.Close()
	l.file = nil
	return err
}

// Format is one line as the log writes it: the time (UTC, RFC 3339), the
// level padded to five, the message, and a newline.
func Format(at time.Time, level Level, msg string) string {
	return fmt.Sprintf("%s %-5s %s\n", at.UTC().Format(time.RFC3339), level, strings.TrimRight(msg, "\n"))
}

// Line is one line of the log, read back.
type Line struct {
	At    time.Time
	Level Level
	Text  string
	// Raw is the line as written, without its newline.
	Raw string
	// Continued: the line didn't start with a time and a level (a message
	// that ran over several lines). It takes the line before it's time and
	// level.
	Continued bool
}

// Parse reads one line; a line that doesn't start with a time and a level
// is Continued, its At and Level left for the caller to fill.
func Parse(raw string) Line {
	raw = strings.TrimRight(raw, "\r\n")
	ln := Line{Raw: raw, Text: raw, Continued: true}
	stamp, rest, ok := strings.Cut(raw, " ")
	if !ok {
		return ln
	}
	at, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		return ln
	}
	word, text, _ := strings.Cut(strings.TrimLeft(rest, " "), " ")
	for i, n := range names {
		if word == n {
			return Line{At: at, Level: Level(i), Text: strings.TrimLeft(text, " "), Raw: raw}
		}
	}
	return ln
}

// Read reads every line of dir's log, the rotated file's first, each
// continued line given the time and level of the one before it.
func Read(dir string) ([]Line, error) {
	var lines []Line
	for _, name := range []string{Rotated, File} {
		f, err := os.Open(filepath.Join(dir, name))
		if os.IsNotExist(err) {
			continue
		} else if err != nil {
			return nil, err
		}
		lines, err = ReadFrom(f, lines)
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	return lines, nil
}

// ReadFrom appends r's lines to lines, as Read does.
func ReadFrom(r io.Reader, lines []Line) ([]Line, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		ln := Parse(sc.Text())
		if ln.Continued && len(lines) > 0 {
			prev := lines[len(lines)-1]
			ln.At, ln.Level = prev.At, prev.Level
		} else if ln.Continued {
			ln.Level = Info
		}
		lines = append(lines, ln)
	}
	return lines, sc.Err()
}

// capped is daemon.log: appended to, and moved to the rotated name (the
// one before it dropped) once it reaches MaxSize.
type capped struct {
	path, rotated string
	f             *os.File
	size          int64
}

func openCapped(path, rotated string) (*capped, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &capped{path: path, rotated: rotated, f: f, size: st.Size()}, nil
}

func (c *capped) write(line string) {
	if c.size > 0 && c.size+int64(len(line)) > MaxSize {
		c.rotate()
	}
	n, _ := io.WriteString(c.f, line)
	c.size += int64(n)
}

// rotate moves the file aside and starts a new one. If that fails the old
// file is truncated instead, so the log never grows without bound.
func (c *capped) rotate() {
	c.f.Close()
	_ = os.Remove(c.rotated)
	flags := os.O_CREATE | os.O_APPEND | os.O_WRONLY
	if err := os.Rename(c.path, c.rotated); err != nil {
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(c.path, flags, 0o600)
	if err != nil {
		// Nowhere to write: keep the closed handle; writes fail quietly
		// and stderr still has every line.
		return
	}
	c.f, c.size = f, 0
}
