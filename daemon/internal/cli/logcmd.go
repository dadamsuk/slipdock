package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/daemonlog"
	"github.com/dadamsuk/slipdock/daemon/internal/daemonstate"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
)

// followEvery is how often log --follow looks for new lines. A var so
// tests can shorten it.
var followEvery = time.Second

// cmdLog prints the daemon's log, or a runner's job log, from the machine's
// own files (#2652).
func cmdLog(args []string, env Env) error {
	fs, home := newFlags("log", env)
	levelFlag := fs.String("level", "", "only lines at this level or above: debug, info, warn or error")
	follow := fs.Bool("follow", false, "keep printing lines as they are written")
	fs.BoolVar(follow, "f", false, "the same as --follow")
	runnerFlag := fs.String("runner", "", "a runner's job log (its name or id), not the daemon's")
	job := fs.Int64("job", 0, "the job log of the runner that holds or last held this job")
	sinceFlag := fs.String("since", "", "only lines from this long ago (30m, 2h, 3d)")
	n := fs.Int("n", 50, "the last N lines (0: all)")
	if err := parse(fs, args); err != nil {
		return err
	}
	if *runnerFlag != "" && *job != 0 {
		fmt.Fprintln(env.Stderr, "slipdock-runner log: --runner or --job, not both")
		return errUsage
	}
	jobLog := *runnerFlag != "" || *job != 0
	if jobLog && (*levelFlag != "" || *sinceFlag != "") {
		fmt.Fprintln(env.Stderr, "slipdock-runner log: a job's log has no levels or times: --level and --since read the daemon's log")
		return errUsage
	}
	// No --level is every line the daemon wrote (run's --log-level
	// decided what that was).
	min := daemonlog.Debug
	if *levelFlag != "" {
		var err error
		if min, err = daemonlog.ParseLevel(*levelFlag); err != nil {
			fmt.Fprintf(env.Stderr, "slipdock-runner log: %v\n", err)
			return errUsage
		}
	}
	var since time.Time
	if *sinceFlag != "" {
		dur, err := parseSince(*sinceFlag)
		if err != nil {
			fmt.Fprintf(env.Stderr, "slipdock-runner log: %v\n", err)
			return errUsage
		}
		since = now().Add(-dur)
	}
	if *n < 0 {
		fmt.Fprintln(env.Stderr, "slipdock-runner log: -n is a count of lines, 0 or more")
		return errUsage
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	if jobLog {
		path, err := jobLogPath(d, *runnerFlag, *job)
		if err != nil {
			return err
		}
		return tailFile(env, path, *n, *follow, func(daemonlog.Line) bool { return true }, false)
	}
	keep := func(l daemonlog.Line) bool {
		return l.Level >= min && (since.IsZero() || !l.At.Before(since))
	}
	return tailFile(env, filepath.Join(d, daemonlog.File), *n, *follow, keep, true)
}

// parseSince reads a duration: Go's (30m, 1h30m), or a number of days (3d).
func parseSince(s string) (time.Duration, error) {
	if days, ok := strings.CutSuffix(s, "d"); ok {
		if n, err := strconv.Atoi(days); err == nil && n >= 0 {
			return time.Duration(n) * 24 * time.Hour, nil
		}
	}
	dur, err := time.ParseDuration(s)
	if err != nil || dur < 0 {
		return 0, fmt.Errorf("--since %q is not a duration such as 30m, 2h or 3d", s)
	}
	return dur, nil
}

// jobLogPath finds a runner's job.log: by the runner's name or id, or by
// a job it holds or held last (each runner keeps only its last job's log).
func jobLogPath(d, name string, job int64) (string, error) {
	jobsDir := filepath.Join(d, "jobs")
	if job != 0 {
		entries, _ := os.ReadDir(jobsDir)
		for _, e := range entries {
			id, err := strconv.ParseInt(e.Name(), 10, 64)
			if err != nil || !e.IsDir() {
				continue
			}
			if j, _ := daemonstate.LoadJob(jobsDir, id); j != nil && j.ID == job {
				return filepath.Join(jobsDir, e.Name(), "job.log"), nil
			}
		}
		return "", fmt.Errorf("job #%d isn't the job any runner here holds or held last; each runner keeps only its last job's log", job)
	}
	cache, err := machineconfig.ReadCache(d)
	if err != nil {
		return "", err
	}
	id, err := strconv.ParseInt(strings.TrimPrefix(name, "#"), 10, 64)
	if err != nil {
		id = 0
		if cache != nil {
			for _, l := range cache.Runners {
				if l.Name == name {
					id = l.ID
				}
			}
		}
		if id == 0 {
			return "", fmt.Errorf("no runner here is called %q (status lists them)", name)
		}
	}
	path := filepath.Join(jobsDir, fmt.Sprint(id), "job.log")
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("runner %s has no job log yet: it hasn't run a job on this machine", name)
	}
	return path, nil
}

// tailFile prints the last n of path's lines that keep accepts (all of
// them for n 0), with daemon the rotated daemon.log read first; then,
// following, the lines written after, until the process is asked to stop.
// A file that shrinks (rotated, or a new job's log) is read again from
// its start.
func tailFile(env Env, path string, n int, follow bool, keep func(daemonlog.Line) bool, daemon bool) error {
	var lines []daemonlog.Line
	if daemon {
		f, err := os.Open(filepath.Join(filepath.Dir(path), daemonlog.Rotated))
		if err == nil {
			lines, err = daemonlog.ReadFrom(f, lines)
			f.Close()
			if err != nil {
				return err
			}
		}
	}
	data, err := os.ReadFile(path)
	missing := os.IsNotExist(err)
	if err != nil && !missing {
		return err
	}
	if missing && !follow && len(lines) == 0 {
		fmt.Fprintf(env.Stderr, "no log yet at %s: the daemon writes it once it runs\n", path)
		return nil
	}
	offset := int64(len(data))
	lines, err = daemonlog.ReadFrom(strings.NewReader(string(data)), lines)
	if err != nil {
		return err
	}
	var kept []daemonlog.Line
	for _, l := range lines {
		if keep(l) && strings.TrimSpace(l.Raw) != "" {
			kept = append(kept, l)
		}
	}
	if n > 0 && len(kept) > n {
		kept = kept[len(kept)-n:]
	}
	for _, l := range kept {
		fmt.Fprintln(env.Stdout, l.Raw)
	}
	if !follow {
		return nil
	}
	var last *daemonlog.Line
	if len(lines) > 0 {
		last = &lines[len(lines)-1]
	}
	ctx, cancel := env.Context()
	defer cancel()
	sleep := env.Sleep
	if sleep == nil {
		sleep = sleepCtx
	}
	for {
		if err := sleep(ctx, followEvery); err != nil || ctx.Err() != nil {
			return nil
		}
		offset, last = printNew(env, path, offset, last, keep)
	}
}

// printNew prints what path gained after offset, and answers the new
// offset and the last line read (a continued line takes its level).
func printNew(env Env, path string, offset int64, last *daemonlog.Line, keep func(daemonlog.Line) bool) (int64, *daemonlog.Line) {
	f, err := os.Open(path)
	if err != nil {
		return offset, last
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return offset, last
	}
	if st.Size() < offset {
		offset = 0
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return offset, last
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return offset, last
	}
	// Only whole lines: a line still being written waits for the next look.
	end := strings.LastIndexByte(string(data), '\n') + 1
	var lines []daemonlog.Line
	if last != nil {
		lines = append(lines, *last)
	}
	lines, _ = daemonlog.ReadFrom(strings.NewReader(string(data[:end])), lines)
	if last != nil {
		lines = lines[1:]
	}
	for _, l := range lines {
		if keep(l) && strings.TrimSpace(l.Raw) != "" {
			fmt.Fprintln(env.Stdout, l.Raw)
		}
	}
	if len(lines) > 0 {
		last = &lines[len(lines)-1]
	}
	return offset + int64(end), last
}

// sleepCtx waits d, or until ctx ends.
func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
