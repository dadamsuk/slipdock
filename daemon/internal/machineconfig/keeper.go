// Package machineconfig keeps the machine's runners' configs as the server
// changes them, inside the machine's ceiling (W-2541, W-2544 part 3).
//
// Each runner's config is checked against the ceiling as it arrives. Inside
// it, it is accepted and reported with its version. Outside it, it is
// rejected and reported with the reason, and the runner keeps its last
// accepted config, or doesn't run if it never had one. What was accepted
// is cached on disk, so a daemon that starts while the server can't be
// reached starts from it. Every change is written to a local change log,
// field by field.
package machineconfig

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
)

// CacheFile holds the last accepted config, in the machine's directory.
const CacheFile = "config-cache.json"

// ChangeLog is the local log of every config change, in the machine's directory.
const ChangeLog = "changes.log"

// Reporter tells the server what was done with a runner's config.
type Reporter interface {
	Report(ctx context.Context, runnerID, version int64, outcome, reason string) error
}

// Report is what was, or is to be, said about one runner's config.
type Report struct {
	Version int64  `json:"version"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

// cache is CacheFile's shape.
type cache struct {
	Version  int64            `json:"version"`
	Runners  []runner.Listed  `json:"runners"`
	Reported map[int64]Report `json:"reported"`
}

// Keeper holds the machine's accepted config. Not safe for concurrent use:
// the daemon's config loop is its only caller.
type Keeper struct {
	// Dir is the machine's directory: the cache and the change log are there.
	Dir     string
	Ceiling machine.Ceiling
	Server  Reporter
	Logf    func(string, ...any)
	Now     func() time.Time

	version  int64
	accepted map[int64]runner.Listed
	reported map[int64]Report
	pending  map[int64]Report
}

func (k *Keeper) init() {
	if k.accepted == nil {
		k.accepted = map[int64]runner.Listed{}
		k.reported = map[int64]Report{}
		k.pending = map[int64]Report{}
	}
	if k.Logf == nil {
		k.Logf = func(string, ...any) {}
	}
	if k.Now == nil {
		k.Now = time.Now
	}
}

// Version is the machine's config version last taken in.
func (k *Keeper) Version() int64 { return k.version }

// Load reads the cached config, if there is one, and says whether there
// was. A cached runner now outside the ceiling (a person at the machine
// narrowed it since) is dropped.
func (k *Keeper) Load() (bool, error) {
	k.init()
	data, err := os.ReadFile(filepath.Join(k.Dir, CacheFile))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var c cache
	if err := json.Unmarshal(data, &c); err != nil {
		return false, fmt.Errorf("%s: %w", filepath.Join(k.Dir, CacheFile), err)
	}
	k.version = c.Version
	for _, l := range c.Runners {
		if err := l.Check(k.Ceiling); err != nil {
			k.Logf("cached runner %s (#%d) is outside this machine's ceiling now, so it doesn't run: %v", l.Name, l.ID, err)
			continue
		}
		k.accepted[l.ID] = l
	}
	for id, r := range c.Reported {
		k.reported[id] = r
	}
	return true, nil
}

// Running is the runners to run: each accepted one not paused, by id.
func (k *Keeper) Running() []runner.Runner {
	k.init()
	var out []runner.Runner
	for _, l := range k.accepted {
		if !l.Paused {
			out = append(out, l.Runner)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Apply takes in the server's listing: each runner checked against the
// ceiling, every change logged, the outcome queued to report (Flush sends
// it), and what was accepted cached. It answers the runners to run.
func (k *Keeper) Apply(l *runner.Listing) []runner.Runner {
	k.init()
	listed := map[int64]bool{}
	for _, r := range l.Runners {
		listed[r.ID] = true
		k.take(r)
	}
	for id, old := range k.accepted {
		if !listed[id] {
			k.change(fmt.Sprintf("runner %s (#%d) removed: it finishes the job it holds, then stops", old.Name, id))
			delete(k.accepted, id)
			delete(k.reported, id)
			delete(k.pending, id)
		}
	}
	k.version = l.Version
	if err := k.save(); err != nil {
		k.Logf("can't cache the accepted config: %v", err)
	}
	return k.Running()
}

// take checks one listed runner against the ceiling and keeps it, or keeps
// what it had.
func (k *Keeper) take(r runner.Listed) {
	old, had := k.accepted[r.ID]
	err := r.Check(k.Ceiling)
	if err == nil {
		if !had || !reflect.DeepEqual(old, r) {
			what := "added"
			if had {
				what = "changed"
			}
			k.change(fmt.Sprintf("runner %s (#%d) v%d %s and accepted: %s", r.Name, r.ID, r.ConfigVersion, what, diff(old, r)))
		}
		k.accepted[r.ID] = r
		k.queue(r.ID, Report{Version: r.ConfigVersion, Outcome: "accepted"})
		return
	}
	// Outside the ceiling: what was accepted stays, but a pause, which
	// only narrows, is taken.
	if k.reported[r.ID] != (Report{Version: r.ConfigVersion, Outcome: "rejected", Reason: err.Error()}) {
		kept := "it doesn't run"
		if had {
			kept = fmt.Sprintf("it keeps v%d", old.ConfigVersion)
		}
		k.change(fmt.Sprintf("runner %s (#%d) v%d rejected, %s: %s (%s)", r.Name, r.ID, r.ConfigVersion, kept, err, diff(old, r)))
		if had {
			k.Logf("runner %s (#%d) v%d is outside this machine's ceiling, so it keeps v%d: %v", r.Name, r.ID, r.ConfigVersion, old.ConfigVersion, err)
		} else {
			k.Logf("runner %s (#%d) is outside this machine's ceiling, so it doesn't run: %v", r.Name, r.ID, err)
		}
	}
	if had && old.Paused != r.Paused {
		k.change(fmt.Sprintf("runner %s (#%d) %s", old.Name, r.ID, map[bool]string{true: "paused", false: "resumed"}[r.Paused]))
		old.Paused = r.Paused
		k.accepted[r.ID] = old
	}
	k.queue(r.ID, Report{Version: r.ConfigVersion, Outcome: "rejected", Reason: err.Error()})
}

// queue keeps a report to send, unless it was sent already.
func (k *Keeper) queue(id int64, r Report) {
	if k.reported[id] == r {
		delete(k.pending, id)
		return
	}
	k.pending[id] = r
}

// Flush sends the reports not yet sent. One that fails stays, to be sent
// at the next Flush.
func (k *Keeper) Flush(ctx context.Context) {
	k.init()
	ids := make([]int64, 0, len(k.pending))
	for id := range k.pending {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	sent := false
	for _, id := range ids {
		r := k.pending[id]
		if err := k.Server.Report(ctx, id, r.Version, r.Outcome, r.Reason); err != nil {
			k.Logf("can't report runner #%d's config v%d (%s) yet: %v", id, r.Version, r.Outcome, err)
			continue
		}
		k.reported[id] = r
		delete(k.pending, id)
		sent = true
	}
	if sent {
		if err := k.save(); err != nil {
			k.Logf("can't cache the accepted config: %v", err)
		}
	}
}

// Pending is how many reports are waiting to be sent.
func (k *Keeper) Pending() int { return len(k.pending) }

// change writes a line to the change log, and to the daemon's log.
func (k *Keeper) change(line string) {
	k.Logf("%s", line)
	f, err := os.OpenFile(filepath.Join(k.Dir, ChangeLog), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		k.Logf("can't write the change log: %v", err)
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", k.Now().UTC().Format(time.RFC3339), line)
}

// save writes the cache: written whole to a temporary file, then renamed,
// so a crash never leaves half of one.
func (k *Keeper) save() error {
	c := cache{Version: k.version, Reported: k.reported}
	for _, l := range k.accepted {
		c.Runners = append(c.Runners, l)
	}
	sort.Slice(c.Runners, func(i, j int) bool { return c.Runners[i].ID < c.Runners[j].ID })
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(k.Dir, CacheFile+".*")
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
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(k.Dir, CacheFile))
}

// diff lists each field that differs between a and b, as name "old" →
// "new": the runner's name, board, pool and pause, then each of its config
// fields by its JSON name.
func diff(a, b runner.Listed) string {
	var out []string
	add := func(name string, x, y any) {
		if !reflect.DeepEqual(x, y) {
			out = append(out, fmt.Sprintf("%s %s → %s", name, show(x), show(y)))
		}
	}
	add("name", a.Name, b.Name)
	add("board", a.BoardID, b.BoardID)
	add("pool", a.Pool, b.Pool)
	add("paused", a.Paused, b.Paused)
	ca, cb := reflect.ValueOf(a.Config), reflect.ValueOf(b.Config)
	t := ca.Type()
	for i := 0; i < t.NumField(); i++ {
		name := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		if name == "" {
			name = t.Field(i).Name
		}
		add(name, ca.Field(i).Interface(), cb.Field(i).Interface())
	}
	if len(out) == 0 {
		return "no field changed"
	}
	return strings.Join(out, "; ")
}

func show(v any) string {
	if s, ok := v.(string); ok {
		return fmt.Sprintf("%q", s)
	}
	return fmt.Sprint(v)
}
