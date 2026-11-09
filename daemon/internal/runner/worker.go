package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// Worker is one runner's loop: claim a job, run it, report it, claim the
// next. One job at a time.
type Worker struct {
	Runner  Runner
	Client  *Client
	Local   machine.Local
	Version string
	// JobsDir holds each runner's job log, owner-only.
	JobsDir string
	// Home is the home of the account jobs run as: transcripts, skills and
	// the CLI's tokens are found from it.
	Home string
	// SharedDir: another of the machine's runners works in the same
	// directory, so worktree "auto" means a worktree per job.
	SharedDir bool

	Logf     func(format string, a ...any)
	Getenv   func(string) string
	LookPath func(string) (string, error)
	Exec     execFunc

	// The protocol's pace, as the shell runner's defaults.
	Wait            int           // seconds a claim waits for a job (25)
	Heartbeat       time.Duration // between heartbeats (20 s)
	TranscriptEvery time.Duration // between transcript sends (60 s; < 0 off)
	Grace           time.Duration // between asking a job to stop and making it (10 s)
	LogTail         int           // bytes of log a heartbeat carries (8000)
	Tick            time.Duration // how often a running job is looked at (1 s)
	// Timeout overrides the config's timeout_minutes (tests).
	Timeout time.Duration
	// Sleep waits between claims that failed; it returns early when ctx ends.
	Sleep func(context.Context, time.Duration) error
}

// Defaults fills what wasn't set.
func (w *Worker) defaults() {
	if w.Wait == 0 {
		w.Wait = 25
	}
	if w.Heartbeat == 0 {
		w.Heartbeat = 20 * time.Second
	}
	if w.TranscriptEvery == 0 {
		w.TranscriptEvery = 60 * time.Second
	}
	if w.Grace == 0 {
		w.Grace = 10 * time.Second
	}
	if w.LogTail == 0 {
		w.LogTail = 8000
	}
	if w.Tick == 0 {
		w.Tick = time.Second
	}
	if w.Logf == nil {
		w.Logf = func(string, ...any) {}
	}
	if w.Getenv == nil {
		w.Getenv = os.Getenv
	}
	if w.LookPath == nil {
		w.LookPath = exec.LookPath
	}
	if w.Exec == nil {
		w.Exec = realExec
	}
	if w.Sleep == nil {
		w.Sleep = sleepCtx
	}
}

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

func realExec(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (w *Worker) say(format string, a ...any) {
	w.Logf("runner %s (#%d): %s", w.Runner.Name, w.Runner.ID, fmt.Sprintf(format, a...))
}

// Run claims and runs jobs until ctx ends (nil), or the server refuses the
// runner (a *Refused: the machine revoked, or the runner no longer the
// machine's). A claim that fails otherwise is tried again, backing off to
// a minute.
func (w *Worker) Run(ctx context.Context) error {
	w.defaults()
	backoff := time.Second
	w.say("taking jobs from %s (pool %s, board #%d)", w.Client.Server, w.Runner.Pool, w.Runner.BoardID)
	for ctx.Err() == nil {
		headers := claimHeaders(w.Runner.Kinds(w.Local), w.Version, w.skillsDir(), w.cliPath())
		job, info, err := w.Client.Claim(ctx, w.Runner.ID, headers, w.Wait)
		var refusal *Refused
		switch {
		case ctx.Err() != nil:
			return nil
		case errors.As(err, &refusal):
			return err
		case err != nil:
			w.say("could not reach the queue (%v); trying again in %s", err, backoff)
			if w.Sleep(ctx, backoff) != nil {
				return nil
			}
			backoff = min(backoff*2, time.Minute)
		case job == nil:
			backoff = time.Second
			if info.RetryAfter > 0 && w.Sleep(ctx, info.RetryAfter) != nil {
				return nil
			}
		default:
			backoff = time.Second
			w.runJob(ctx, job)
		}
	}
	return nil
}

func (w *Worker) skillsDir() string {
	if w.Local.SkillsDir != "" {
		return w.Local.SkillsDir
	}
	return filepath.Join(w.Home, ".claude", "skills")
}

func (w *Worker) cliPath() string {
	if w.Local.CLI != "" {
		return w.Local.CLI
	}
	p, _ := w.LookPath("slipdock")
	return p
}

func (w *Worker) transcriptsDir() string {
	if w.Local.Transcripts != "" {
		return w.Local.Transcripts
	}
	if d := w.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return filepath.Join(d, "projects")
	}
	return filepath.Join(w.Home, ".claude", "projects")
}

// jobRun is one job in flight: its log file, and what the after hook and
// the finish need.
type jobRun struct {
	job     *Job
	log     *os.File
	logPath string
	env     []string
	dir     string
	lane    *lane
	after   *machine.Command
}

func (j *jobRun) note(line string) {
	line = strings.TrimRight(line, "\n")
	if line != "" {
		fmt.Fprintln(j.log, line)
	}
}

// runJob runs one claimed job and reports how it ended. Whatever happens,
// the server hears of it, unless the daemon itself is stopping: then the
// job is stopped and nothing is said, so its lease runs out and it goes
// back to the queue for another runner.
func (w *Worker) runJob(ctx context.Context, job *Job) {
	dir := filepath.Join(w.JobsDir, fmt.Sprint(w.Runner.ID))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		w.say("job #%d: can't make %s: %v", job.ID, dir, err)
		w.finish(ctx, job, nil, 1, "failed", "", "slipdock-runner: can't make the job's log: "+err.Error())
		return
	}
	logPath := filepath.Join(dir, "job.log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_TRUNC|os.O_RDWR, 0o600)
	if err != nil {
		w.say("job #%d: can't open %s: %v", job.ID, logPath, err)
		w.finish(ctx, job, nil, 1, "failed", "", "slipdock-runner: can't open the job's log: "+err.Error())
		return
	}
	defer f.Close()
	j := &jobRun{job: job, log: f, logPath: logPath, dir: w.Runner.Config.Directory}

	kinds := w.Runner.Kinds(w.Local)
	if !contains(kinds, job.Kind) {
		w.say("job #%d: kind %q isn't one this runner takes (%s): refused, nothing run", job.ID, job.Kind, strings.Join(kinds, ", "))
		j.note(fmt.Sprintf("no such job kind: %s (this runner takes %s)", job.Kind, strings.Join(kinds, ", ")))
		w.finish(ctx, job, j, 127, "failed", "", "")
		return
	}
	sum := sha256.Sum256([]byte(job.Prompt))
	w.say("job #%d: %s for card #%d in %s (prompt sha256 %s)", job.ID, job.Kind, job.CardID, j.dir, hex.EncodeToString(sum[:])[:16])
	if job.Kind == "merge" {
		w.runMerge(ctx, j)
		return
	}
	if job.Kind == ProbeKind {
		w.runProbe(ctx, j)
		return
	}
	w.runAgent(ctx, j)
}

// prepare checks everything the job needs before anything runs: the agent's
// program and every hook the runner names must be defined on this machine,
// and the directory must be there. The error is why the job didn't start.
func (w *Worker) prepare(j *jobRun) (*exec.Cmd, *machine.Command, error) {
	c := w.Runner.Config
	agent, ok := w.Local.Agent(c.Agent)
	if !ok {
		return nil, nil, fmt.Errorf("agent %q is not defined in this machine's %s, so the job was not run", c.Agent, machine.LocalFile)
	}
	path, err := w.resolve(agent.Path)
	if err != nil {
		return nil, nil, fmt.Errorf("agent %q: %s is not on the PATH of the account jobs run as, so the job was not run", c.Agent, agent.Path)
	}
	var before *machine.Command
	for _, h := range []struct {
		which, name string
		set         **machine.Command
	}{{"before", c.BeforeHook, &before}, {"after", c.AfterHook, &j.after}} {
		if h.name == "" {
			continue
		}
		hook, ok := w.Local.Hook(h.name)
		if !ok {
			return nil, nil, fmt.Errorf("the %s hook %q is not defined in this machine's %s, so the job was not run", h.which, h.name, machine.LocalFile)
		}
		resolved, err := w.resolve(hook.Path)
		if err != nil {
			return nil, nil, fmt.Errorf("the %s hook %q: %s is not on the PATH, so the job was not run", h.which, h.name, hook.Path)
		}
		hook.Path = resolved
		*h.set = &hook
	}
	if fi, err := os.Stat(c.Directory); err != nil || !fi.IsDir() {
		return nil, nil, fmt.Errorf("the working directory %s is not there, so the job was not run", c.Directory)
	}
	return w.agentCommand(c, agent, path, j.job), before, nil
}

func (w *Worker) resolve(path string) (string, error) {
	if filepath.IsAbs(path) {
		if _, err := os.Stat(path); err != nil {
			return path, err
		}
		return path, nil
	}
	return w.LookPath(path)
}

// prompt is the server's prompt, with this runner's standing instructions
// after it, except on a verify job, whose agent checks the work rather than
// doing it.
func (w *Worker) prompt(job *Job) string {
	if ins := strings.TrimSpace(w.Runner.Config.Instructions); ins != "" && job.Kind != "verify" {
		return job.Prompt + "\n\n" + ins
	}
	return job.Prompt
}

// model is the local file's model for the card's profile, else the runner's.
func (w *Worker) model(job *Job) string {
	if m := w.Local.Models[job.Profile]; job.Profile != "" && m != "" {
		return m
	}
	return w.Runner.Config.Model
}

// agentCommand is the agent's command line: claude and codex as the shell
// runner's installer writes them, a custom command as the local file has
// it, with the prompt only in $SLIPDOCK_PROMPT.
func (w *Worker) agentCommand(c Config, agent machine.Command, path string, job *Job) *exec.Cmd {
	args := append([]string(nil), agent.Args...)
	prompt, model := w.prompt(job), w.model(job)
	switch c.Agent {
	case "claude":
		args = append(args, "-p", prompt, "--permission-mode", c.PermissionMode)
		if len(agent.AllowedTools) > 0 {
			args = append(args, "--allowedTools", strings.Join(agent.AllowedTools, ","))
		}
		if model != "" {
			args = append(args, "--model", model)
		}
	case "codex":
		args = append(args, "exec")
		if model != "" {
			args = append(args, "-m", model)
		}
		args = append(args, prompt)
	}
	return exec.Command(path, args...)
}

// jobEnv is the SLIPDOCK_* environment a job and its hooks get.
func (w *Worker) jobEnv(j *jobRun) []string {
	job := j.job
	env := append(inherited(),
		fmt.Sprintf("SLIPDOCK_JOB_ID=%d", job.ID),
		"SLIPDOCK_JOB_KIND="+job.Kind,
		"SLIPDOCK_CARD="+cardText(job.CardID),
		"SLIPDOCK_CARD_URL="+job.CardURL,
		"SLIPDOCK_PROMPT="+w.prompt(job),
		"SLIPDOCK_PROFILE="+job.Profile,
		"SLIPDOCK_MODEL="+w.model(job),
		fmt.Sprintf("SLIPDOCK_RUNNER_ID=%d", w.Runner.ID),
	)
	if j.lane != nil {
		env = append(env, "SLIPDOCK_WORKTREE="+j.lane.path)
	}
	if w.Runner.Config.Agent == "claude" {
		// Print mode stops a run's background tasks (the subagents a pass
		// hands its builds to) 10 minutes after its last turn; 0 waits (#1812).
		env = append(env, "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0")
	}
	return env
}

// jobVars are what the daemon sets for a job and its hooks. The daemon's
// own environment never passes one on: a stale SLIPDOCK_EXIT, say, from
// whatever started the daemon, would read as this job's.
var jobVars = []string{"SLIPDOCK_JOB_ID", "SLIPDOCK_JOB_KIND", "SLIPDOCK_CARD", "SLIPDOCK_CARD_URL",
	"SLIPDOCK_PROMPT", "SLIPDOCK_PROFILE", "SLIPDOCK_MODEL", "SLIPDOCK_RUNNER_ID", "SLIPDOCK_WORKTREE",
	"SLIPDOCK_EXIT", "SLIPDOCK_STATUS", "SLIPDOCK_MERGE_PR", "SLIPDOCK_MERGE_COMMIT", "SLIPDOCK_MERGED_FILE",
	"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", "PWD"}

// inherited is the daemon's environment without jobVars.
func inherited() []string {
	var env []string
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		if !contains(jobVars, strings.ToUpper(name)) {
			env = append(env, kv)
		}
	}
	return env
}

func cardText(id int64) string {
	if id == 0 {
		return ""
	}
	return fmt.Sprint(id)
}

func (j *jobRun) where() string {
	if j.lane != nil {
		return j.lane.path
	}
	return j.dir
}

// runAgent runs an agent job: the checks, the worktree, the before hook,
// the agent, watched, then the after hook and the finish.
func (w *Worker) runAgent(ctx context.Context, j *jobRun) {
	job := j.job
	cmd, before, err := w.prepare(j)
	if err != nil {
		w.say("job #%d: %v", job.ID, err)
		j.note("slipdock-runner: " + err.Error())
		w.finish(ctx, job, j, 127, "failed", "", "")
		return
	}
	wt := w.Runner.Config.Worktree
	if wt == "on" || (wt == "auto" && w.SharedDir) {
		if j.lane, err = openLane(ctx, w.Exec, j.dir, job.CardID, j.note); err != nil {
			w.say("job #%d: no worktree for it, so not run: %v", job.ID, err)
			j.note("slipdock-runner: " + err.Error())
			j.env = w.jobEnv(j)
			w.afterHook(ctx, j, 1, "failed")
			w.finish(ctx, job, j, 1, "failed", "", "")
			return
		}
	}
	j.env = w.jobEnv(j)

	if before != nil {
		if rc := w.hook(ctx, j, *before, j.env); rc != 0 {
			w.say("job #%d: the before hook failed (exit %d), so the job was not run", job.ID, rc)
			j.note(fmt.Sprintf("slipdock-runner: the before hook failed (exit %d), so the job was not run", rc))
			w.afterHook(ctx, j, rc, "failed")
			j.lane.close(ctx, w.Exec, j.note)
			w.finish(ctx, job, j, rc, "failed", "", "")
			return
		}
	}

	cmd.Dir = j.where()
	cmd.Env = append(j.env, "PWD="+cmd.Dir)
	cmd.Stdout, cmd.Stderr = j.log, j.log
	inGroup(cmd)
	tx := &transcript{root: w.transcriptsDir(), cardURL: job.CardURL, started: time.Now().Add(-time.Second),
		secrets: machineSecrets(w.Client.Key, w.Home, w.Getenv)}
	if err := cmd.Start(); err != nil {
		j.note("slipdock-runner: the agent didn't start: " + err.Error())
		w.afterHook(ctx, j, 127, "failed")
		j.lane.close(ctx, w.Exec, j.note)
		w.finish(ctx, job, j, 127, "failed", "", "")
		return
	}
	done := make(chan int, 1)
	go func() {
		err := cmd.Wait()
		done <- exitCode(cmd, err)
	}()
	stop := func() { w.stopTree(cmd, done) }
	ended, rc := w.watch(ctx, j, done, stop, tx)
	w.end(ctx, j, ended, rc, "", tx)
}

func exitCode(cmd *exec.Cmd, err error) int {
	if cmd.ProcessState != nil {
		if c := cmd.ProcessState.ExitCode(); c >= 0 {
			return c
		}
	}
	if err != nil {
		return 1
	}
	return 0
}

// stopTree stops the job and everything it started: asked first, made
// after the grace.
func (w *Worker) stopTree(cmd *exec.Cmd, done chan int) {
	signalTree(cmd, false)
	exited := false
	select {
	case <-done:
		exited = true
	case <-time.After(w.Grace):
	}
	// Made, whether or not the job itself went: its children may outlive it.
	signalTree(cmd, true)
	if !exited {
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	}
}

// watch waits for the job, renewing its lease with heartbeats that carry
// the log's tail and sending the transcript as it grows. ended is "" when
// the job ended by itself (rc its exit code), else timeout, cancelled
// (from the board), lost (the lease went to another) or shutdown (the
// daemon is stopping); the job has been stopped in each of those.
func (w *Worker) watch(ctx context.Context, j *jobRun, done chan int, stop func(), tx *transcript) (string, int) {
	timeout := w.Timeout
	if timeout == 0 {
		timeout = time.Duration(w.Runner.Config.TimeoutMinutes) * time.Minute
	}
	deadline := time.Now().Add(timeout)
	lastBeat, lastTx := time.Time{}, time.Now()
	tick := time.NewTicker(w.Tick)
	defer tick.Stop()
	for {
		select {
		case rc := <-done:
			return "", rc
		case <-ctx.Done():
			stop()
			return "shutdown", 130
		case now := <-tick.C:
			if now.After(deadline) {
				stop()
				return "timeout", 124
			}
			if now.Sub(lastBeat) >= w.Heartbeat {
				lastBeat = now
				cancel, err := w.Client.Heartbeat(ctx, w.Runner.ID, j.job.ID, w.tail(j))
				switch {
				case errors.Is(err, ErrLost):
					stop()
					return "lost", 130
				case err == nil && cancel:
					stop()
					return "cancelled", 130
				}
			}
			if tx != nil && w.TranscriptEvery > 0 && now.Sub(lastTx) >= w.TranscriptEvery {
				lastTx = now
				w.sendTranscript(ctx, j, tx, false)
			}
		}
	}
}

// end reports how the job ended, as the shell runner does each case.
func (w *Worker) end(ctx context.Context, j *jobRun, ended string, rc int, merged string, tx *transcript) {
	job := j.job
	status := ""
	switch ended {
	case "shutdown":
		w.say("job #%d: the daemon is stopping, so the job was stopped; its lease runs out and it goes back to the queue", job.ID)
		// A fresh context: the daemon's has ended, and the hook and the
		// worktree still need tidying.
		bg, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		w.afterHook(bg, j, 130, "cancelled")
		j.lane.close(bg, w.Exec, j.note)
		return
	case "lost":
		w.say("job #%d: no longer this runner's, so it was stopped", job.ID)
		w.afterHook(ctx, j, 130, "cancelled")
		j.lane.close(ctx, w.Exec, j.note)
		return
	case "timeout":
		w.say("job #%d: over its %d minutes, so it was stopped", job.ID, w.Runner.Config.TimeoutMinutes)
		j.note(fmt.Sprintf("slipdock-runner: stopped after %d minutes", w.Runner.Config.TimeoutMinutes))
		status = "timeout"
	case "cancelled":
		w.say("job #%d: cancelled from the board, so it was stopped", job.ID)
		j.note("slipdock-runner: cancelled from the board")
		status = "cancelled"
	default:
		w.say("job #%d: exit %d in %s", job.ID, rc, j.where())
	}
	if tx != nil {
		w.sendTranscript(ctx, j, tx, true)
	}
	switch {
	case status != "":
		w.afterHook(ctx, j, rc, status)
	case rc == 0:
		w.afterHook(ctx, j, 0, "done")
	default:
		w.afterHook(ctx, j, rc, "failed")
	}
	j.lane.close(ctx, w.Exec, j.note)
	w.finish(ctx, job, j, rc, status, merged, "")
}

// runMerge runs the built-in merge in the runner's repository, watched like
// any job (heartbeats, cancel, timeout), with no agent and no transcript.
func (w *Worker) runMerge(ctx context.Context, j *jobRun) {
	mctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan int, 1)
	var merged string
	go func() {
		sha, err := merge(mctx, w.Exec, j.dir, j.job, j.note)
		var me *mergeExit
		switch {
		case errors.As(err, &me):
			j.note(me.msg)
			done <- me.code
		case err != nil:
			j.note("merge: " + err.Error())
			done <- 1
		default:
			merged = sha
			done <- 0
		}
	}()
	stop := func() {
		cancel()
		select {
		case rc := <-done:
			done <- rc
		case <-time.After(w.Grace):
		}
	}
	ended, rc := w.watch(ctx, j, done, stop, nil)
	if ended == "" && rc == 0 {
		w.end(ctx, j, ended, rc, merged, nil)
		return
	}
	w.end(ctx, j, ended, rc, "", nil)
}

// hook runs a hook in the job's directory, its output in the job's log,
// stopped with the job's tree if the daemon stops. Its exit code.
func (w *Worker) hook(ctx context.Context, j *jobRun, h machine.Command, env []string) int {
	cmd := exec.Command(h.Path, h.Args...)
	cmd.Dir = j.where()
	cmd.Env = append(env, "PWD="+cmd.Dir)
	cmd.Stdout, cmd.Stderr = j.log, j.log
	inGroup(cmd)
	if err := cmd.Start(); err != nil {
		j.note("slipdock-runner: the hook didn't start: " + err.Error())
		return 127
	}
	done := make(chan int, 1)
	go func() { done <- exitCode(cmd, cmd.Wait()) }()
	select {
	case rc := <-done:
		return rc
	case <-ctx.Done():
		w.stopTree(cmd, done)
		return 130
	}
}

// afterHook runs the after hook, if the runner names one, however the job
// ended, with SLIPDOCK_EXIT and SLIPDOCK_STATUS (done, failed, cancelled
// or timeout).
func (w *Worker) afterHook(ctx context.Context, j *jobRun, rc int, status string) {
	if j.after == nil {
		return
	}
	env := append(append([]string(nil), j.env...), fmt.Sprintf("SLIPDOCK_EXIT=%d", rc), "SLIPDOCK_STATUS="+status)
	if code := w.hook(ctx, j, *j.after, env); code != 0 {
		w.say("job #%d: the after hook failed (exit %d)", j.job.ID, code)
	}
}

// sendTranscript sends the transcript's new lines. A failed send is left
// for the next; at the end (final) it sends until caught up, trying a
// failed send three more times.
func (w *Worker) sendTranscript(ctx context.Context, j *jobRun, tx *transcript, final bool) {
	if w.TranscriptEvery < 0 || tx.done || !tx.find() {
		return
	}
	rounds, retries := 2, 0
	if final {
		rounds = 50
	}
	for ; rounds > 0; rounds-- {
		body := tx.next()
		if len(body) == 0 {
			return
		}
		held, capped, err := w.Client.Transcript(ctx, w.Runner.ID, j.job.ID, tx.lines, body)
		switch {
		case err == nil && capped:
			j.note("slipdock-runner: the server's log for this job is full; the rest of the transcript is not sent")
			tx.done = true
			return
		case err == nil:
			if held == tx.lines {
				return // nothing taken: don't spin
			}
			tx.lines = held
		default:
			retries++
			if !final || retries > 3 {
				return
			}
			_ = w.Sleep(ctx, time.Duration(retries)*time.Second)
		}
	}
}

// tail is the end of the job's log.
func (w *Worker) tail(j *jobRun) []byte {
	if j == nil {
		return nil
	}
	f, err := os.Open(j.logPath)
	if err != nil {
		return nil
	}
	defer f.Close()
	if fi, err := f.Stat(); err == nil && fi.Size() > int64(w.LogTail) {
		_, _ = f.Seek(-int64(w.LogTail), io.SeekEnd)
	}
	data, _ := io.ReadAll(f)
	return data
}

// finish reports the job's end with its log's tail (or text, when there is
// no log). A finish that can't be reported is logged: the lease runs out.
func (w *Worker) finish(ctx context.Context, job *Job, j *jobRun, rc int, status, merged, text string) {
	body := []byte(text)
	if j != nil {
		body = w.tail(j)
	}
	if ctx.Err() != nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
	}
	sleep := func(d time.Duration) { _ = w.Sleep(ctx, d) }
	if err := w.Client.Finish(ctx, w.Runner.ID, job.ID, rc, status, merged, body, sleep); err != nil {
		w.say("job #%d: could not report it finished: %v", job.ID, err)
	}
}
