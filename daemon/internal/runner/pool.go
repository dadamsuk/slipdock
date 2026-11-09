package runner

import (
	"context"
	"reflect"
	"sync"
	"sync/atomic"
)

// Pool runs the machine's runners as their config changes (#2575, W-2544
// part 3): Apply starts a worker for a runner that is new, and one that
// changed starts again with its new config once its job has finished. A
// runner left out (removed, or paused) finishes the job it holds, then
// stops. Nothing restarts the process, and a job is never cut short by a
// config change.
type Pool struct {
	ctx     context.Context
	cancel  context.CancelFunc
	logf    func(string, ...any)
	mu      sync.Mutex
	slots   map[int64]*slot
	wg      sync.WaitGroup
	revoked atomic.Bool
	// draining: Drain was called, and Apply starts nothing more.
	draining bool
}

// slot is one runner's worker: stop tells it to finish and end, done is
// closed when it has.
type slot struct {
	worker *Worker
	stop   chan struct{}
	done   chan struct{}
}

// NewPool makes a pool whose workers run until ctx ends, or until one of
// them finds the machine revoked, which stops them all (Context ends).
func NewPool(ctx context.Context, logf func(string, ...any)) *Pool {
	ctx, cancel := context.WithCancel(ctx)
	return &Pool{ctx: ctx, cancel: cancel, logf: logf, slots: map[int64]*slot{}}
}

// Context ends when the pool's does, or when the machine is found revoked.
func (p *Pool) Context() context.Context { return p.ctx }

// Stop stops every worker: what they are running is stopped too.
func (p *Pool) Stop() { p.cancel() }

// Apply makes workers the pool's runners. After Drain it does nothing.
func (p *Pool) Apply(workers []*Worker) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.draining {
		return
	}
	want := map[int64]*Worker{}
	for _, w := range workers {
		want[w.Runner.ID] = w
	}
	for id, s := range p.slots {
		if _, ok := want[id]; !ok {
			p.logf("runner %s (#%d) takes no more jobs: it stops once the job it holds has finished", s.worker.Runner.Name, id)
			close(s.stop)
			delete(p.slots, id)
		}
	}
	for id, w := range want {
		s := p.slots[id]
		switch {
		case s == nil:
			p.slots[id] = p.start(w, nil)
		case same(s.worker, w):
		default:
			p.logf("runner %s (#%d) changed: it starts again with its new config once the job it holds has finished", w.Runner.Name, id)
			close(s.stop)
			p.slots[id] = p.start(w, s.done)
		}
	}
}

// Drain stops the pool taking jobs, for good (#2618): every worker
// finishes the job it holds and ends, and Apply starts no more. It returns
// once they all have, or the pool's context has ended, so the daemon can
// restart on an update it installed without cutting a job short.
func (p *Pool) Drain() {
	p.mu.Lock()
	if !p.draining {
		p.draining = true
		for id, s := range p.slots {
			p.logf("runner %s (#%d) takes no more jobs: it stops once the job it holds has finished", s.worker.Runner.Name, id)
			close(s.stop)
			delete(p.slots, id)
		}
	}
	p.mu.Unlock()
	p.wg.Wait()
}

// Draining says whether Drain has been called.
func (p *Pool) Draining() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.draining
}

// same: nothing a worker runs with differs, its config version aside.
func same(a, b *Worker) bool {
	ra, rb := a.Runner, b.Runner
	ra.ConfigVersion, rb.ConfigVersion = 0, 0
	return reflect.DeepEqual(ra, rb) && a.SharedDir == b.SharedDir
}

// start runs w in a slot of its own once after (the worker it replaces)
// has ended.
func (p *Pool) start(w *Worker, after <-chan struct{}) *slot {
	s := &slot{worker: w, stop: make(chan struct{}), done: make(chan struct{})}
	client := *w.Client
	client.Stop = s.stop
	run := *w
	run.Client = &client
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		defer close(s.done)
		if after != nil {
			select {
			case <-after:
			case <-p.ctx.Done():
				return
			}
		}
		select {
		case <-s.stop: // left out again before it started
			return
		default:
		}
		if err := keep(p.ctx, &run, p.logf); IsRevoked(err) {
			p.revoked.Store(true)
			p.cancel()
		}
	}()
	return s
}

// Wait waits for every worker to end, and says ErrRevoked if the machine
// was found revoked.
func (p *Pool) Wait() error {
	p.wg.Wait()
	p.cancel()
	if p.revoked.Load() {
		return ErrRevoked
	}
	return nil
}
