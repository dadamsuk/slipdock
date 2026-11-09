package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/enrol"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
	"github.com/dadamsuk/slipdock/daemon/internal/update"
)

// checkEvery is how often run asks the server whether the machine is still
// enrolled. A var so tests can shorten it.
var checkEvery = 5 * time.Minute

// updateEvery is how often run checks for a newer release, in checks of
// the enrolment: every 6 hours, and once at the start.
var updateEvery = int((6 * time.Hour) / checkEvery)

// configRetry is how long run waits to ask again for the machine's config
// when the server can't be reached. A var so tests can shorten it.
var configRetry = 30 * time.Second

// ceilingRetryMax is the longest run waits between tries to report the
// ceiling: each try after a failure waits twice as long as the last,
// from configRetry, up to this. A var so tests can shorten it.
var ceilingRetryMax = 5 * time.Minute

// cmdRun is what the service runs: the machine's runners, each taking and
// running jobs (#2574), and the enrolment kept checked. It stops when the
// machine is revoked or the process is asked to.
func cmdRun(args []string, env Env) error {
	fs, home := newFlags("run", env)
	logPath := fs.String("log", "", "append the daemon's log to this file, not stderr")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	var w io.Writer = env.Stderr
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	logger := log.New(w, "slipdock-runner: ", log.LstdFlags)

	st, key, err := machine.Load(d)
	if err != nil {
		return err
	}
	ceil, err := machine.LoadCeiling(d)
	if err != nil {
		return fmt.Errorf("the ceiling: %w", err)
	}
	local, err := machine.LoadLocal(d)
	if err != nil {
		return fmt.Errorf("the local file: %w", err)
	}
	client := enrol.NewClient(st.Server, "slipdock-runner/"+Version)
	if env.HTTP != nil {
		client.HTTP = env.HTTP
	}
	sleep := client.Sleep
	if env.Sleep != nil {
		sleep = env.Sleep
	}
	ctx, cancel := env.Context()
	defer cancel()

	logger.Printf("%s %s starting as %s (machine #%d) on %s", "slipdock-runner", Version, st.Name, st.MachineID, st.Server)
	if exe, err := env.Executable(); err == nil {
		update.Cleanup(exe)
	}
	// The first check comes before the runners start, so an update found
	// then restarts the daemon before it has taken a job.
	if err := autoUpdate(ctx, d, env, logger.Printf); err != nil {
		return err
	}

	// The runners run beside the enrolment check; the machine revoked
	// (seen by either) or the process stopping ends both.
	// A later update drains them first (#2618): closing drain stops their
	// claims, and idle is closed once the jobs they held have finished.
	ctx, stopAll := context.WithCancel(ctx)
	revoked := make(chan struct{})
	drain, idle := make(chan struct{}), make(chan struct{})
	var runners sync.WaitGroup
	runners.Add(1)
	go func() {
		defer runners.Done()
		if err := runRunners(ctx, d, st, key, ceil, local, env, client.Sleep, logger.Printf, drain, idle); errors.Is(err, runner.ErrRevoked) {
			close(revoked)
			stopAll()
		}
	}()
	defer func() {
		stopAll()
		runners.Wait()
	}()

	for n := 1; ; n++ {
		if n%updateEvery == 0 {
			if err := autoUpdate(ctx, d, env, logger.Printf); err != nil {
				return restartWhenIdle(ctx, err, drain, idle, revoked, logger.Printf)
			}
		}
		m, err := client.Me(ctx, key)
		switch {
		case enrol.IsUnauthorized(err) || (err == nil && m.State == "revoked"):
			return fmt.Errorf("the server no longer accepts this machine (revoked): run init --replace to enrol it again")
		case err != nil && ctx.Err() == nil:
			logger.Printf("can't reach the server, trying again: %v", err)
		case err == nil:
			logger.Printf("enrolled as %s, serving %s", m.Name, boardList(m.Boards))
		}
		if err := sleep(ctx, checkEvery); err != nil || ctx.Err() != nil {
			select {
			case <-revoked:
				return runner.ErrRevoked
			default:
			}
			logger.Printf("stopping")
			return nil
		}
	}
}

// restartWhenIdle is run after an update installed while its runners run
// (#2618): they take no more jobs, and run ends with err, to restart on the
// new binary, once the jobs they hold have finished. A job is never cut
// short by an update; the process asked to stop meanwhile ends at once.
func restartWhenIdle(ctx context.Context, err error, drain chan<- struct{}, idle, revoked <-chan struct{}, logf func(string, ...any)) error {
	logf("the runners take no more jobs: restarting once the jobs they hold have finished")
	close(drain)
	select {
	case <-idle:
		logf("the runners are idle: restarting on the new version")
	case <-ctx.Done():
	}
	select {
	case <-revoked:
		return runner.ErrRevoked
	default:
		return err
	}
}

// configWait is how long each of run's asks for the machine's config waits
// for a change (the server's most).
const configWait = 50

// runRunners runs the machine's runners and keeps them to the machine's
// config as the server changes it (#2575): each change checked against the
// ceiling and reported, applied between jobs, without a restart. Until the
// server first answers, it runs what was last accepted, from the cache.
// pause waits between asks, returning early when ctx ends. Once drain is
// closed the runners take no more jobs, and idle is closed when the jobs
// they held have finished (#2618).
func runRunners(ctx context.Context, d string, st machine.State, key string, ceil machine.Ceiling, local machine.Local, env Env,
	pause func(context.Context, time.Duration) error, logf func(string, ...any), drain <-chan struct{}, idle chan<- struct{}) error {
	hc := &http.Client{}
	if env.HTTP != nil && env.HTTP.Transport != nil {
		hc.Transport = env.HTTP.Transport
	}
	client := &runner.Client{Server: st.Server, Key: key, HTTP: hc, UserAgent: "slipdock-runner/" + Version}
	home, _ := env.UserHome()
	base := runner.Worker{
		Client:   client,
		Local:    local,
		Version:  Version,
		JobsDir:  filepath.Join(d, "jobs"),
		Home:     home,
		Logf:     logf,
		Getenv:   env.Getenv,
		LookPath: env.LookPath,
	}
	pool := runner.NewPool(ctx, logf)
	ctx = pool.Context()
	go func() {
		select {
		case <-drain:
			pool.Drain()
			close(idle)
		case <-ctx.Done():
		}
	}()
	keeper := &machineconfig.Keeper{Dir: d, Ceiling: ceil, Server: client, Logf: logf}
	apply := func(running []runner.Runner, listed int) {
		if pool.Draining() {
			logf("config version %d: no runner starts, as the daemon restarts for an update", keeper.Version())
			return
		}
		workers, _ := runner.Build(&runner.MachineConfig{Version: keeper.Version(), Runners: running}, ceil, base)
		pool.Apply(workers)
		logf("config version %d: %d of %d runners running", keeper.Version(), len(workers), listed)
	}

	go reportCeiling(ctx, client, ceil, pause, logf)

	cached, err := keeper.Load()
	if err != nil {
		logf("can't read the cached config, so waiting for the server's: %v", err)
	}
	since, wait, started := int64(-1), 0, false
	for {
		l, err := client.FetchConfig(ctx, since, wait)
		switch {
		case ctx.Err() != nil:
			return pool.Wait()
		case runner.IsRevoked(err):
			pool.Stop()
			pool.Wait()
			return runner.ErrRevoked
		case err != nil:
			if !started && cached {
				logf("the server can't be reached, so starting from the cached config (version %d)", keeper.Version())
				apply(keeper.Running(), len(keeper.Running()))
				started = true
			}
			logf("can't read this machine's runners, trying again in %s: %v", configRetry, err)
			if pause(ctx, configRetry) != nil {
				return pool.Wait()
			}
			continue
		case l != nil && (since < 0 || l.Version > since):
			apply(keeper.Apply(l), len(l.Runners))
			since, wait, started = l.Version, configWait, true
		case l != nil:
			// An answer at once with nothing newer: don't ask again at once.
			if pause(ctx, configRetry) != nil {
				return pool.Wait()
			}
		}
		keeper.Flush(ctx)
	}
}

// reportCeiling tells the server the machine's ceiling and the executors it
// offers (#2615), trying again until it is sent. The ceiling is the one
// this run read at the start: changed at the machine, it takes effect when
// the daemon restarts, and the restarted run reports it then. A refusal
// (the key revoked, the ceiling found invalid) is logged and not retried:
// the same ceiling would be refused again. It ends when ctx does.
func reportCeiling(ctx context.Context, client *runner.Client, ceil machine.Ceiling,
	pause func(context.Context, time.Duration) error, logf func(string, ...any)) {
	wait := configRetry
	for {
		err := client.ReportCeiling(ctx, ceil)
		var refused *runner.Refused
		switch {
		case err == nil:
			logf("reported the ceiling (executors %s)", strings.Join(ceil.Reported().Executors, ", "))
			return
		case ctx.Err() != nil:
			return
		case errors.As(err, &refused):
			logf("the server refused the ceiling, so not reporting it again until the daemon restarts: %v", err)
			return
		}
		logf("can't report the ceiling, trying again in %s: %v", wait, err)
		if pause(ctx, wait) != nil {
			return
		}
		wait = min(2*wait, ceilingRetryMax)
	}
}
