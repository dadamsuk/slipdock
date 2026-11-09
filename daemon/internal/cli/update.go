package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
	"github.com/dadamsuk/slipdock/daemon/internal/update"
)

// releaseKey is the key updates must be signed with: the one embedded in
// the binary. A var so tests can sign with their own.
var releaseKey = release.Key

// now is the clock update checks are stamped with. A var for tests.
var now = time.Now

// errRestart ends run after an update was installed, so the service starts
// the new binary (systemd and launchd restart it whatever the exit; the
// Windows task restarts it on a failure, which this is to it).
var errRestart = errors.New("updated: exiting so the service starts the new version")

// cmdUpdate checks for a newer signed release and installs it, or with
// --check only says whether there is one. --mode and --source change how
// the service treats updates, and where they come from.
func cmdUpdate(args []string, env Env) error {
	fs, home := newFlags("update", env)
	checkOnly := fs.Bool("check", false, "only say whether a newer release exists")
	mode := fs.String("mode", "", "how the service treats a newer release: auto (install it) or manual (report it)")
	source := fs.String("source", "", "where releases come from (a URL, or default)")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	s, err := update.Load(d)
	if err != nil {
		return err
	}
	if *mode != "" || *source != "" {
		return setUpdateSettings(d, s, *mode, *source, env.Stdout)
	}
	u, err := updater(s, env)
	if err != nil {
		return err
	}
	ctx, cancel := env.Context()
	defer cancel()
	c, err := u.Run(ctx, !*checkOnly, now())
	s.Last = &c
	if serr := update.Save(d, s); serr != nil && err == nil {
		err = serr
	}
	switch {
	case update.IsRefused(err):
		return fmt.Errorf("%v: nothing was installed, and this binary is as it was (from %s)", err, u.Source)
	case err != nil:
		return err
	}
	switch c.Outcome {
	case update.Current:
		fmt.Fprintf(env.Stdout, "Up to date: %s (the latest release is %s).\n", Version, c.Latest)
	case update.Available:
		fmt.Fprintf(env.Stdout, "%s is available (this is %s): slipdock-runner update installs it.\n", c.Latest, Version)
	case update.Installed:
		fmt.Fprintf(env.Stdout, "Updated %s to %s, signature and checksum checked.\n", Version, c.Latest)
		fmt.Fprintln(env.Stdout, "A service already running runs the old one until it restarts: slipdock-runner service install restarts it.")
	}
	return nil
}

func setUpdateSettings(d string, s update.Settings, mode, source string, out io.Writer) error {
	if mode != "" {
		if mode != update.Auto && mode != update.Manual {
			return fmt.Errorf("--mode is auto or manual, not %q", mode)
		}
		s.Mode = mode
	}
	switch source {
	case "":
	case "default":
		s.Source = ""
	default:
		s.Source = source
	}
	if err := update.Save(d, s); err != nil {
		return err
	}
	fmt.Fprintf(out, "Updates: %s, from %s.\n", s.ModeOrDefault(), s.SourceOrDefault())
	return nil
}

func updater(s update.Settings, env Env) (update.Updater, error) {
	exe, err := env.Executable()
	if err != nil {
		return update.Updater{}, fmt.Errorf("can't tell where this binary is: %w", err)
	}
	key, err := releaseKey()
	if err != nil && !errors.Is(err, release.ErrNoKey) {
		return update.Updater{}, err
	}
	return update.Updater{
		HTTP: env.HTTP, Source: s.SourceOrDefault(), Key: key, Current: Version,
		GOOS: env.GOOS, GOARCH: env.GOARCH, Exe: exe, UserAgent: "slipdock-runner/" + Version,
	}, nil
}

// autoUpdate is run's check: in auto mode a newer release is installed and
// run ends to restart on it; in manual mode it is only logged. A refusal is
// logged loudly and kept in update.json, where show and doctor report it.
// A dev build doesn't update itself.
func autoUpdate(ctx context.Context, d string, env Env, logf func(string, ...any)) error {
	if !release.IsRelease(Version) {
		return nil
	}
	s, err := update.Load(d)
	if err != nil {
		logf("updates: %v", err)
		return nil
	}
	u, err := updater(s, env)
	if err != nil {
		logf("updates: %v", err)
		return nil
	}
	install := s.ModeOrDefault() == update.Auto
	c, err := u.Run(ctx, install, now())
	s.Last = &c
	if serr := update.Save(d, s); serr != nil {
		logf("updates: can't record the check: %v", serr)
	}
	switch {
	case update.IsRefused(err):
		logf("REFUSED an update from %s: %s (nothing was installed)", u.Source, c.Reason)
	case err != nil:
		logf("can't check for updates, trying later: %v", err)
	case c.Outcome == update.Available:
		logf("%s is available (this is %s); updates are manual: slipdock-runner update installs it", c.Latest, Version)
	case c.Outcome == update.Installed:
		logf("updated %s to %s, signature and checksum checked; restarting", Version, c.Latest)
		return errRestart
	}
	return nil
}

// updateLines say how updates stand, for show and doctor.
func updateLines(d string) (mode string, last *update.Check, err error) {
	s, err := update.Load(d)
	if err != nil {
		return "", nil, err
	}
	return fmt.Sprintf("%s, from %s", s.ModeOrDefault(), s.SourceOrDefault()), s.Last, nil
}

// updateCheck is doctor's line on updates.
func updateCheck(d string) (string, string, string) {
	what := "updates"
	mode, last, err := updateLines(d)
	switch {
	case err != nil:
		return fail, what, err.Error()
	case !release.IsRelease(Version):
		return warn, what, "a " + Version + " build doesn't update itself: install a release for signed updates"
	case last == nil:
		return ok, what, mode + "; not checked yet"
	case last.Outcome == update.Refused:
		return fail, what, fmt.Sprintf("the update checked %s was refused: %s. Nothing was installed. Check where updates come from (%s)",
			last.At.Format(time.RFC3339), last.Reason, mode)
	case last.Outcome == update.Available:
		return warn, what, fmt.Sprintf("%s; %s is available: slipdock-runner update installs it", mode, last.Latest)
	case last.Outcome == update.Failed:
		return warn, what, fmt.Sprintf("%s; the last check failed: %s", mode, last.Reason)
	default:
		return ok, what, fmt.Sprintf("%s; %s, checked %s", mode, last.Outcome, last.At.Format(time.RFC3339))
	}
}
