package runner

import (
	"context"
	"fmt"
	"regexp"
	"strings"
)

// execFunc runs a program in dir and returns what it printed (stdout and
// stderr together). A var in the worker so tests can stand in for git and gh.
type execFunc func(ctx context.Context, dir, name string, args ...string) (string, error)

var prURL = regexp.MustCompile(`^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)/*$`)

// mergeExit is a merge refused before anything changed (2), or one gh
// refused (3), as the shell runner's job_merge says them.
type mergeExit struct {
	code int
	msg  string
}

func (e *mergeExit) Error() string { return e.msg }

// merge is the built-in merge kind (#1656), the shell runner's job_merge:
// the pull request and the accepted commit are data from the server,
// checked here before use. It merges only a pull request in dir's own
// origin, still open, whose head is the accepted commit, and answers the
// merge commit. log gets what a person reads afterwards.
func merge(ctx context.Context, run execFunc, dir string, job *Job, log func(string)) (string, error) {
	fail := func(code int, format string, a ...any) (string, error) {
		return "", &mergeExit{code, "merge: " + fmt.Sprintf(format, a...)}
	}
	pr, want := job.MergePR, job.MergeCommit
	if pr == "" {
		return fail(2, "the card names no pull request (its evidence has no PR URL)")
	}
	if want == "" {
		return fail(2, "the card names no accepted commit")
	}
	m := prURL.FindStringSubmatch(pr)
	if m == nil {
		return fail(2, "%s is not a GitHub pull request URL", pr)
	}
	prRepo, num := m[1], m[2]
	if !isHex(want) {
		return fail(2, "the accepted commit %s is not a commit id", want)
	}
	origin, err := run(ctx, dir, "git", "remote", "get-url", "origin")
	if err != nil {
		return fail(2, "%s has no origin remote", dir)
	}
	if !strings.EqualFold(repoOf(strings.TrimSpace(origin)), prRepo) {
		return fail(2, "the pull request is in %s, but this runner's repository is %s; nothing merged", prRepo, strings.TrimSpace(origin))
	}
	if _, err := run(ctx, dir, "gh", "auth", "status"); err != nil {
		return fail(2, "gh is not signed in (run gh auth login)")
	}
	info, err := run(ctx, dir, "gh", "pr", "view", num, "--repo", prRepo, "--json", "state,headRefOid", "--jq", `.state + " " + .headRefOid`)
	if err != nil {
		return fail(2, "could not read %s: %s", pr, oneLine(info))
	}
	state, head, _ := strings.Cut(strings.TrimSpace(info), " ")
	if state != "OPEN" {
		return fail(2, "%s is %s, not open; nothing merged", pr, state)
	}
	if !strings.HasPrefix(strings.ToLower(head), strings.ToLower(want)) {
		return fail(2, "%s's head is %s, not the accepted commit %s (it moved after the card was accepted); nothing merged", pr, head, want)
	}
	card := "?"
	if job.CardID > 0 {
		card = fmt.Sprint(job.CardID)
	}
	// gh's own words are the reason (#1666): a conflict reads differently
	// from a failing check or branch protection.
	said, err := run(ctx, dir, "gh", "pr", "merge", num, "--repo", prRepo, "--merge", "--match-head-commit", head,
		"--subject", fmt.Sprintf("Merge PR %s: card #%s", num, card))
	if err != nil {
		reason := oneLine(said)
		if reason == "" {
			reason = "gh gave no reason"
		}
		return fail(3, "gh pr merge refused %s: %s", pr, reason)
	}
	if s := strings.TrimSpace(said); s != "" {
		log(s)
	}
	sha, _ := run(ctx, dir, "gh", "pr", "view", num, "--repo", prRepo, "--json", "mergeCommit", "--jq", ".mergeCommit.oid")
	sha = strings.TrimSpace(sha)
	shown := sha
	if shown == "" {
		shown = "an unknown commit"
	}
	log(fmt.Sprintf("merge: merged %s (head %s) as %s", pr, head, shown))
	return sha, nil
}

// repoOf is owner/name from a GitHub remote URL (https or ssh).
func repoOf(origin string) string {
	r := strings.TrimSuffix(strings.TrimRight(origin, "/"), ".git")
	if m := remoteURL.FindStringSubmatch(r); m != nil {
		return m[1]
	}
	return r
}

// remoteURL is a GitHub remote, owner/name after the host: ssh (scp-like, or ssh://),
// or https with or without a token in it.
var remoteURL = regexp.MustCompile(`^(?:ssh://git@github\.com/|git@github\.com:|https://(?:[^@/]*@)?github\.com/)(.+)$`)

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
