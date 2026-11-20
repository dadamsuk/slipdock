package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// A verify job (#3522) runs in the container executor, whatever its
// runner's own executor, with no credentials of the machine's: no CLI
// login, no git or gh login, no ~/.ssh, no keys but its agent's. It gets
// instead:
//
//   - its own clone of the repository, made by the daemon with the
//     machine's git, at the submitted commit, with the origin's branches
//     (the job never sees the runner's own repository, so nothing it
//     writes there reaches the daemon's git);
//   - on a board that ships by pull request, the pull request's head,
//     base and checks, read by the daemon with the machine's gh once its
//     checks have finished ($SLIPDOCK_PR_STATE, $SLIPDOCK_BASE);
//   - the job's own token ($SLIPDOCK_TOKEN, from the claim's X-Job-Token),
//     which reports the verdict and the job's steps and reads the
//     handbook's rules, and the server ($SLIPDOCK_URL).
//
// The server says what the job is; the machine decides how it runs
// (ARCH-5). A machine that can't run a container (no container executor
// in its ceiling, or no image allowed for it) takes no verify jobs.

// verifyKind is the job kind a verify job has.
const verifyKind = "verify"

// prStateMax caps what of the pull request's state the job gets.
const prStateMax = 64 << 10

// baseRef is a branch name the daemon will hand on as $SLIPDOCK_BASE.
var baseRef = regexp.MustCompile(`^[A-Za-z0-9._/-]{1,200}$`)

// verifyImage is the image a verify job runs in: a container runner's
// own, else the local file's container.verify_image.
func (w *Worker) verifyImage() string {
	c := w.Runner.Config
	if c.Executor == executor.Container && c.Image != "" {
		return c.Image
	}
	if ct := w.Local.Container; ct != nil {
		return ct.VerifyImage
	}
	return ""
}

// canVerify says why this runner can't run a verify job in a container,
// or nil.
func (w *Worker) canVerify() error {
	goos := w.GOOS
	if goos == "" {
		goos = runtime.GOOS
	}
	if err := executor.Supported(executor.Container, goos); err != nil {
		return err
	}
	if !contains(w.Offered, executor.Container) {
		return errors.New("the machine's ceiling doesn't offer the container executor, which a verify job runs under")
	}
	image := w.verifyImage()
	if image == "" {
		return errors.New("no image to run a verify job in: set container.verify_image in the local file")
	}
	return executor.ImageAllowed(image, w.Images)
}

// kinds are the job kinds this runner says it takes: its runner's, less
// verify when it can't run one in a container.
func (w *Worker) kinds() []string {
	kinds := w.Runner.Kinds(w.Local)
	if w.Runner.Config.Agent == verifyKind || w.canVerify() == nil {
		return kinds
	}
	out := kinds[:0:0]
	for _, k := range kinds {
		if k != verifyKind {
			out = append(out, k)
		}
	}
	return out
}

// forVerify is the worker a verify job runs on: a copy of this one (the
// runner's, under its trust tier's limits) in the container executor, in
// the job's own clone, mounting only the agent's login. A runner that
// isn't a container runner keeps its hooks out of the container: they
// were written for the machine.
func (w *Worker) forVerify(job *Job, clone string) (*Worker, error) {
	if err := w.canVerify(); err != nil {
		return nil, fmt.Errorf("a verify job runs in a container, and this runner can't run one: %v, so the job was not run", err)
	}
	c := w.Runner.Config
	if c.Executor != executor.Container {
		c.BeforeHook, c.AfterHook = "", ""
	}
	c.Image, c.Executor = w.verifyImage(), executor.Container
	c.Directory, c.Worktree = clone, "off"
	jw := *w
	jw.Runner.Config = c
	jw.verify, jw.jobToken = true, job.Token
	jw.Executor, jw.executorErr, jw.Exec = nil, nil, nil
	jw.defaults()
	w.say("job #%d: verify: in a container (%s), in its own clone, with its own token and its agent's login alone", job.ID, c.Image)
	return &jw, nil
}

// verifyLogins are what a verify job's container mounts and passes in:
// the agent's own login and keys, nothing else of the machine's.
func (w *Worker) verifyLogins(s *executor.Settings) {
	agent := w.Runner.Config.Agent
	s.Login = executor.AgentLogin(w.Home, agent)
	switch agent {
	case "claude", "codex":
		s.PassEnv = executor.DefaultPassEnv(agent)
	default:
		// A custom agent's keys are what the local file passes.
		s.PassEnv = []string{}
		if ct := w.Local.Container; ct != nil && ct.Env != nil {
			s.PassEnv = append(s.PassEnv, ct.Env...)
		}
	}
}

// runVerify runs a verify job: its clone and the pull request's state,
// made with the machine's own git and gh, then its agent in a container.
func (w *Worker) runVerify(ctx context.Context, j *jobRun) {
	job := j.job
	fail := func(err error) {
		w.say("job #%d: %v", job.ID, err)
		j.note("slipdock-runner: " + err.Error())
		w.finish(ctx, job, j, 127, "failed", "", "")
	}
	tw, err := w.forTier(job)
	if err != nil {
		fail(err)
		return
	}
	if err := tw.canVerify(); err != nil {
		fail(fmt.Errorf("a verify job runs in a container, and this runner can't run one: %v, so the job was not run", err))
		return
	}
	clone, err := w.verifyClone(ctx, j)
	if err != nil {
		fail(err)
		return
	}
	defer os.RemoveAll(filepath.Dir(clone))
	state, base, ended := w.prState(ctx, j)
	switch ended {
	case "cancelled":
		j.note("slipdock-runner: cancelled from the board")
		w.finish(ctx, job, j, 130, "cancelled", "", "")
		return
	case "lost", "shutdown":
		return
	}
	vw, err := tw.forVerify(job, clone)
	if err != nil {
		fail(err)
		return
	}
	j.dir = clone
	j.extra = []string{"SLIPDOCK_URL=" + w.Client.Server}
	if job.Token != "" {
		j.extra = append(j.extra, "SLIPDOCK_TOKEN="+job.Token)
	}
	if state != "" {
		j.extra = append(j.extra, "SLIPDOCK_PR_STATE="+state)
	}
	if base != "" {
		j.extra = append(j.extra, "SLIPDOCK_BASE=origin/"+base)
	}
	vw.runAgent(ctx, j)
}

// verifyClone is the job's own clone of the runner's repository, made
// with the machine's git: fetched from origin first, with the origin's
// branches, at the submitted commit. Nothing is linked to the runner's
// repository, so what the job writes stays in the clone. It is the
// "repo" directory of a temporary directory the caller removes.
func (w *Worker) verifyClone(ctx context.Context, j *jobRun) (string, error) {
	job := j.job
	dir := w.Runner.Config.Directory
	note := func(what, out string, err error) {
		j.note(fmt.Sprintf("slipdock-runner: verify: %s: %s", what, failLine(out, err)))
	}
	if out, err := w.Exec(ctx, dir, "git", "fetch", "--quiet", "origin"); err != nil {
		note("git fetch origin failed, so the change is judged as this machine last fetched it", out, err)
	}
	top := dir
	if out, err := w.Exec(ctx, dir, "git", "rev-parse", "--show-toplevel"); err == nil && strings.TrimSpace(out) != "" {
		top = strings.TrimSpace(out)
	}
	tmp, err := os.MkdirTemp("", "slipdock-verify-")
	if err != nil {
		return "", fmt.Errorf("no directory for the verify job's clone, so the job was not run: %v", err)
	}
	clone := filepath.Join(tmp, "repo")
	if out, err := w.Exec(ctx, tmp, "git", "clone", "--quiet", "--no-checkout", "--no-hardlinks", "--", top, clone); err != nil {
		os.RemoveAll(tmp)
		return "", fmt.Errorf("can't clone the repository for the verify job, so the job was not run: %s", failLine(out, err))
	}
	if out, err := w.Exec(ctx, clone, "git", "fetch", "--quiet", "origin", "+refs/remotes/origin/*:refs/remotes/origin/*"); err != nil {
		note("the origin's branches aren't in the clone", out, err)
	}
	checkout := []string{"checkout", "--quiet"}
	if job.VerifyCommit != "" {
		checkout = append(checkout, "--detach", job.VerifyCommit)
	}
	if out, err := w.Exec(ctx, clone, "git", checkout...); err != nil {
		note("the submitted commit isn't on this machine, so the clone isn't at it", out, err)
	}
	return clone, nil
}

// prState is the pull request's head, base and checks, read with the
// machine's gh once no check is still running (or w.CIWait has passed),
// heartbeating the job meanwhile; "" when the job names no pull request
// or gh can't read it. ended is how the job ended while it waited
// (cancelled, lost or shutdown), else "".
func (w *Worker) prState(ctx context.Context, j *jobRun) (state, base, ended string) {
	pr := j.job.VerifyPR
	if pr == "" {
		return "", "", ""
	}
	wait, poll := w.CIWait, w.CIPoll
	if wait == 0 {
		wait = 30 * time.Minute
	}
	if poll == 0 {
		poll = 30 * time.Second
	}
	deadline := w.Now().Add(wait)
	for {
		out, err := w.Exec(ctx, w.Runner.Config.Directory, "gh", "pr", "view", pr, "--json", "headRefOid,baseRefName,statusCheckRollup")
		if err != nil {
			j.note("slipdock-runner: verify: gh can't read the pull request, so the job reads it itself: " + failLine(out, err))
			return "", "", ""
		}
		running, b := readPR(out)
		if !running || !w.Now().Before(deadline) {
			state = strings.TrimSpace(out)
			if len(state) > prStateMax {
				state = state[:prStateMax]
			}
			return state, b, ""
		}
		j.note("slipdock-runner: verify: waiting for the pull request's checks to finish")
		cancel, err := w.Client.Heartbeat(ctx, w.Runner.ID, j.job.ID, w.tail(j))
		switch {
		case errors.Is(err, ErrLost):
			return "", "", "lost"
		case err == nil && cancel:
			return "", "", "cancelled"
		}
		if w.Sleep(ctx, poll) != nil {
			return "", "", "shutdown"
		}
	}
}

// readPR reads gh's answer: whether a check is still running, and the
// base branch (when it reads as one).
func readPR(out string) (running bool, base string) {
	var pr struct {
		BaseRefName       string `json:"baseRefName"`
		StatusCheckRollup []struct {
			Status string `json:"status"`
			State  string `json:"state"`
		} `json:"statusCheckRollup"`
	}
	if json.Unmarshal([]byte(out), &pr) != nil {
		return false, ""
	}
	for _, c := range pr.StatusCheckRollup {
		if (c.Status != "" && c.Status != "COMPLETED") || c.State == "PENDING" || c.State == "EXPECTED" {
			running = true
		}
	}
	if baseRef.MatchString(pr.BaseRefName) && !strings.HasPrefix(pr.BaseRefName, "-") {
		base = pr.BaseRefName
	}
	return running, base
}

// failLine is a command's failure in a line.
func failLine(out string, err error) string {
	if line := strings.TrimSpace(firstLine(strings.TrimSpace(out))); line != "" {
		return line
	}
	if err != nil {
		return err.Error()
	}
	return "it failed"
}
