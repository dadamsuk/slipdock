package runner

import (
	"context"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// ReleaseKind is the built-in release kind (#2836): a batched board's
// release, fired from this machine.
const ReleaseKind = "release"

// defaultBranchMark is what a release command writes for the repository's
// default branch; the daemon puts the branch in.
const defaultBranchMark = "{default_branch}"

var (
	workflowFile = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*\.ya?ml$`)
	branchName   = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_./-]*$`)
	runURL       = regexp.MustCompile(`https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+`)
)

// releaseExit is a release refused before anything ran (2), or a release
// command that failed (3), as mergeExit is for a merge.
type releaseExit struct {
	code int
	msg  string
}

func (e *releaseExit) Error() string { return e.msg }

// fireRelease is the built-in release kind (#2836). The board's release command
// is data from the server, and the daemon never runs what the server sends:
// it runs `gh workflow run <workflow> --ref <branch>` itself when the
// command is exactly that (the workflow's file name and the branch checked
// as names), or the command when this machine's own local.json lists it,
// word for word, under release_commands. Anything else is refused.
//
// {default_branch} in the command is the repository's default branch, read
// from origin after a fresh fetch. gh runs in the repository; a listed
// command runs in a detached worktree of origin's default branch, never a
// card's worktree nor the shared checkout's own branch. It answers the URL
// of the run it started, "" when the command named none. log gets what a
// person reads afterwards, and "release: run <url>" for the server.
func fireRelease(ctx context.Context, run execFunc, dir string, job *Job, listed []string, sleep func(time.Duration), log func(string)) (string, error) {
	fail := func(code int, format string, a ...any) (string, error) {
		return "", &releaseExit{code, "release: " + fmt.Sprintf(format, a...)}
	}
	command := strings.TrimSpace(job.Prompt)
	switch {
	case command == "":
		return fail(2, "the board sent no release command")
	case strings.ContainsAny(command, "\r\n\x00") || len(command) > 500:
		return fail(2, "the release command must be one line of at most 500 characters; nothing run")
	}
	top, err := run(ctx, dir, "git", "rev-parse", "--show-toplevel")
	if err != nil {
		return fail(2, "%s is not a git repository", dir)
	}
	top = filepath.Clean(strings.TrimSpace(top))
	if out, err := run(ctx, top, "git", "fetch", "origin"); err != nil {
		return fail(2, "could not fetch origin: %s", oneLine(out))
	}
	branch := defaultBranch(ctx, run, top)
	if !branchName.MatchString(branch) {
		return fail(2, "could not tell the repository's default branch (git remote set-head origin --auto sets it)")
	}
	argv := strings.Fields(strings.ReplaceAll(command, defaultBranchMark, branch))

	var out string
	workflow, builtIn := workflowRun(argv)
	switch {
	case builtIn:
		if _, err := run(ctx, top, "gh", "auth", "status"); err != nil {
			return fail(2, "gh is not signed in (run gh auth login)")
		}
		before := latestRun(ctx, run, top, workflow, branch)
		out, err = run(ctx, top, "gh", argv[1:]...)
		if err != nil {
			return fail(3, "gh workflow run refused: %s", reason(out))
		}
		url := runURL.FindString(out)
		for try := 0; url == "" && try < 5; try++ {
			sleep(3 * time.Second)
			if now := latestRun(ctx, run, top, workflow, branch); now != "" && now != before {
				url = now
			}
		}
		return released(out, url, log)
	case contains(listed, command):
		path := filepath.Join(top+"-lanes", fmt.Sprintf("release-%d", job.ID))
		if out, err := run(ctx, top, "git", "worktree", "add", "--detach", path, "origin/"+branch); err != nil {
			return fail(2, "could not make the release worktree %s: %s", path, oneLine(out))
		}
		out, err = run(ctx, path, argv[0], argv[1:]...)
		if _, rmErr := run(ctx, top, "git", "worktree", "remove", "--force", path); rmErr != nil {
			log(fmt.Sprintf("release: could not remove the worktree %s", path))
		}
		if err != nil {
			return fail(3, "the release command failed: %s", reason(out))
		}
		return released(out, runURL.FindString(out), log)
	default:
		return fail(2, "this machine runs only `gh workflow run <workflow> --ref <branch>` as a release, or a command its local.json lists under release_commands; nothing run for: %s", command)
	}
}

func released(out, url string, log func(string)) (string, error) {
	if s := strings.TrimSpace(out); s != "" {
		log(s)
	}
	if url == "" {
		log("release: the command ran; it named no run")
		return "", nil
	}
	log("release: run " + url)
	return url, nil
}

// workflowRun reports whether argv is exactly `gh workflow run <workflow>
// --ref <branch>`, the one release the daemon runs by itself, and the
// workflow's file name.
func workflowRun(argv []string) (string, bool) {
	if len(argv) != 6 || argv[0] != "gh" || argv[1] != "workflow" || argv[2] != "run" || argv[4] != "--ref" {
		return "", false
	}
	if !workflowFile.MatchString(argv[3]) || !branchName.MatchString(argv[5]) {
		return "", false
	}
	return argv[3], true
}

// defaultBranch is origin's default branch: what origin/HEAD points at,
// else what gh says of the repository; "" when neither says.
func defaultBranch(ctx context.Context, run execFunc, top string) string {
	if out, err := run(ctx, top, "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil {
		if b := strings.TrimPrefix(strings.TrimSpace(out), "origin/"); b != "" {
			return b
		}
	}
	out, err := run(ctx, top, "gh", "repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// latestRun is the URL of the workflow's newest dispatched run on branch,
// "" if gh names none: read before and after the dispatch, a new one is
// the run the release started (a gh that prints no URL of its own).
func latestRun(ctx context.Context, run execFunc, top, workflow, branch string) string {
	out, err := run(ctx, top, "gh", "run", "list", "--workflow", workflow, "--branch", branch,
		"--event", "workflow_dispatch", "--limit", "1", "--json", "url", "--jq", ".[0].url")
	if err != nil {
		return ""
	}
	return runURL.FindString(out)
}

func reason(out string) string {
	if r := oneLine(out); r != "" {
		return r
	}
	return "it gave no reason"
}
