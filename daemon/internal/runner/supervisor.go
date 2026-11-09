package runner

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"runtime/debug"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// ErrRevoked is the server refusing the machine key: every worker stops.
var ErrRevoked = errors.New("the server no longer accepts this machine (revoked): run init --replace to enrol it again")

// Restart is how long a worker that crashed or failed waits before it
// starts again, doubling to a minute. A var so tests can shorten it.
var Restart = time.Second

// Supervise runs each worker in its own goroutine until ctx ends. A worker
// that panics or fails is logged and started again, so one runner crashing
// leaves the others running. A worker the server refuses (its runner is no
// longer the machine's) stops for good; the machine key refused stops them
// all, and Supervise returns ErrRevoked.
func Supervise(ctx context.Context, workers []*Worker, logf func(string, ...any)) error {
	p := NewPool(ctx, logf)
	p.Apply(workers)
	return p.Wait()
}

// keep runs one worker, starting it again after a crash or a failure. Told
// to stop, its claim answers ErrStopped, a refusal: it ends there.
func keep(ctx context.Context, w *Worker, logf func(string, ...any)) error {
	wait := Restart
	for {
		err := runSafely(ctx, w)
		var refusal *Refused
		switch {
		case ctx.Err() != nil:
			return nil
		case IsRevoked(err):
			logf("runner %s (#%d): %v", w.Runner.Name, w.Runner.ID, err)
			return err
		case errors.As(err, &refusal):
			logf("runner %s (#%d) stopped: %v", w.Runner.Name, w.Runner.ID, err)
			return err
		case err == nil:
			return nil
		}
		logf("runner %s (#%d) crashed, starting it again in %s: %v", w.Runner.Name, w.Runner.ID, wait, err)
		if sleepCtx(ctx, wait) != nil {
			return nil
		}
		wait = min(wait*2, time.Minute)
	}
}

// runSafely runs the worker, turning a panic into an error.
func runSafely(ctx context.Context, w *Worker) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("panic: %v\n%s", p, debug.Stack())
		}
	}()
	return w.Run(ctx)
}

// Build makes a worker for each runner inside the ceiling, and says why
// each other one was left out.
func Build(mc *MachineConfig, ceil machine.Ceiling, base Worker) (workers []*Worker, refused map[int64]error) {
	refused = map[int64]error{}
	dirs := map[string]int{}
	var ok []Runner
	for _, r := range mc.Runners {
		if err := r.Check(ceil); err != nil {
			refused[r.ID] = err
			continue
		}
		ok = append(ok, r)
		dirs[filepath.Clean(r.Config.Directory)]++
	}
	for _, r := range ok {
		w := base
		w.Runner = r
		w.Images = append([]string(nil), ceil.ContainerImages...)
		w.SharedDir = dirs[filepath.Clean(r.Config.Directory)] > 1
		workers = append(workers, &w)
	}
	return workers, refused
}
