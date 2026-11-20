package runner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/egress"
	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// startEgress starts the job's network allowlist (#3517) on w, the job's
// own copy of the worker: its proxy, which lets through only the agent's
// model API, the Slipdock server, the repository's origin and the tier's
// allow_hosts, and the executor that holds the job to it. stop ends the
// proxy when the job is done.
func (w *Worker) startEgress(ctx context.Context, j *jobRun) (stop func(), err error) {
	rules := egress.AgentRules(w.Runner.Config.Agent)
	if w.Client != nil {
		if r, ok := egress.URLRule(w.Client.Server); ok {
			rules = append(rules, r)
		}
	}
	for _, h := range w.allowHosts {
		r, err := egress.ParseRule(h)
		if err != nil {
			return nil, fmt.Errorf("the ceiling's allow_hosts: %v, so the job was not run", err)
		}
		rules = append(rules, r)
	}
	// The machine's own ports (a server on localhost, allow_hosts'
	// localhost:port) are reached directly: NO_PROXY names localhost.
	var direct []int
	for _, r := range rules {
		if r.Loopback() {
			direct = append(direct, r.Port)
		}
	}
	socket, dir := "", ""
	if w.Runner.Config.Executor == executor.Container || w.hookContainer {
		// Short, for a unix socket's path, and outside JobsDir, which is
		// never mounted.
		if dir, err = os.MkdirTemp("", "slipdock-egress-"); err != nil {
			return nil, fmt.Errorf("no directory for the job's proxy: %v, so the job was not run", err)
		}
		socket = filepath.Join(dir, "proxy.sock")
	}
	var tw *egress.Tripwire
	var twDir string
	if w.Runner.Config.Executor == executor.Container {
		// The job's home is its own (a tmpfs), so its fake credentials
		// go there (#3524); never in a home that is the machine's.
		if tw, twDir, err = plantTripwire(); err != nil {
			if dir != "" {
				os.RemoveAll(dir)
			}
			return nil, fmt.Errorf("the job's tripwire: %v, so the job was not run", err)
		}
	}
	tidy := func() {
		for _, d := range []string{dir, twDir} {
			if d != "" {
				os.RemoveAll(d)
			}
		}
	}
	p, err := egress.Start(rules, socket, j.note)
	if err != nil {
		tidy()
		return nil, fmt.Errorf("the job's network allowlist didn't start: %v, so the job was not run", err)
	}
	if tw != nil {
		p.Watch(tw, j.trip)
	}
	stop = func() {
		p.Close()
		tidy()
	}
	w.egress = &executor.Egress{Port: p.Port(), Socket: socket, Direct: direct, Tripwire: twDir}
	w.Executor, w.executorErr, w.Exec = nil, nil, nil
	w.defaults()
	if r, ok := w.origin(ctx, j); ok {
		p.Allow(r)
		if r.Host == "github.com" {
			// gh, for the pull request.
			p.Allow(egress.Rule{Host: "github.com", Port: 443}, egress.Rule{Host: "api.github.com", Port: 443})
		}
	}
	var names []string
	for _, r := range p.Rules() {
		names = append(names, r.String())
	}
	j.note("slipdock-runner: network allowlist: only " + strings.Join(names, ", "))
	return stop, nil
}

// plantTripwire makes a job's fake credentials (#3524) and writes them in
// a directory of their own, outside the daemon's, laid out as a home: the
// container mounts its parts into the job's home.
func plantTripwire() (*egress.Tripwire, string, error) {
	tw, err := egress.NewTripwire()
	if err != nil {
		return nil, "", err
	}
	dir, err := os.MkdirTemp("", "slipdock-tripwire-")
	if err != nil {
		return nil, "", err
	}
	for rel, content := range tw.Files() {
		path := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			os.RemoveAll(dir)
			return nil, "", err
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			os.RemoveAll(dir)
			return nil, "", err
		}
	}
	return tw, dir, nil
}

// origin is the host and port of the repository's origin, which the
// job's allowlist lets through: the one first seen for the runner, kept
// in the daemon's own directory, where no job writes. A job can rewrite
// its repository's .git/config, so a later origin isn't taken: the log
// says how to allow it.
func (w *Worker) origin(ctx context.Context, j *jobRun) (egress.Rule, bool) {
	if w.executorErr != nil || w.Executor.Ready() != nil {
		return egress.Rule{}, false // the job fails before it runs, and says why
	}
	out, err := w.Exec(ctx, j.dir, "git", "remote", "get-url", "origin")
	now, ok := egress.RemoteRule(strings.TrimSpace(out))
	if err != nil || !ok {
		now, ok = egress.Rule{}, false
	}
	if w.JobsDir == "" {
		return now, ok
	}
	pin := filepath.Join(w.JobsDir, fmt.Sprint(w.Runner.ID), "egress-origin")
	if data, err := os.ReadFile(pin); err == nil {
		kept, err := egress.ParseRule(strings.TrimSpace(string(data)))
		if err != nil {
			j.note(fmt.Sprintf("slipdock-runner: network allowlist: %s isn't a host and port, so the origin isn't allowed", pin))
			return egress.Rule{}, false
		}
		if ok && now != kept {
			j.note(fmt.Sprintf("slipdock-runner: network allowlist: the repository's origin is now %s, but the allowlist keeps %s, "+
				"the one first seen; to allow the new one, delete %s", now, kept, pin))
		}
		return kept, true
	}
	if ok {
		if err := os.WriteFile(pin, []byte(now.String()+"\n"), 0o600); err != nil {
			j.note("slipdock-runner: network allowlist: can't keep the origin: " + err.Error())
		}
	}
	return now, ok
}
